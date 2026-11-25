//! The HTTP client the agent artifact tools use (`artifact_save`, `artifact_list`,
//! `memory_search`): one call per tool use, with the same token and HTTP settings as the
//! background sync in `artifacts_sync.rs`.

use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use reqwest::Client;
use serde::Serialize;

use super::{
    BLOB_THRESHOLD, BlobResponse, Change, RepoResponse, SaveRequest, SaveResponse, Trailers,
    ensure_success, http_client, with_query,
};
use crate::config::{ArtifactsSyncConfig, Config};

/// HTTP client shared by the MCP artifact tools and the background synchronizer.
/// It never persists or returns the bearer token.
#[derive(Debug, Clone)]
pub struct ArtifactsClient {
    config: ArtifactsSyncConfig,
    token: Arc<str>,
    client: Client,
}

#[derive(Debug, Serialize)]
struct CreateArtifactRequest<'a> {
    title: &'a str,
    kind: &'a str,
    files: Vec<CreateArtifactFile>,
    trailers: Trailers,
    #[serde(rename = "expectedHeadSha")]
    expected_head_sha: Option<String>,
}

#[derive(Debug, Serialize)]
struct CreateArtifactFile {
    name: String,
    #[serde(rename = "contentBase64")]
    content_base64: String,
    #[serde(skip_serializing_if = "Option::is_none", rename = "contentType")]
    content_type: Option<String>,
}

impl ArtifactsClient {
    /// Build from the daemon config, taking the access token from the same
    /// process credential hand-off used by the mesh client. The token is never
    /// written to config or returned by this client.
    /// Build from the daemon config and the mesh's in-memory access-token
    /// provider. No token is read from disk or environment.
    pub async fn from_runtime_config(config: &Config) -> Result<Option<Self>> {
        if !config.artifacts_sync.enabled {
            return Ok(None);
        }
        let relay = config
            .mesh_relay
            .as_ref()
            .ok_or_else(|| anyhow!("artifacts sync requires meshRelay credentials"))?;
        let hub =
            crate::mesh_http::HttpHub::new(relay).map_err(|error| anyhow!("mesh auth: {error}"))?;
        let token = hub.token(false).await.map_err(|error| anyhow!("mesh auth: {error}"))?;
        Self::from_parts(config.artifacts_sync.clone(), Some(token.as_ref().as_str().to_owned()))
    }

    pub fn from_parts(
        config: ArtifactsSyncConfig,
        access_token: Option<String>,
    ) -> Result<Option<Self>> {
        if !config.enabled {
            return Ok(None);
        }
        let token =
            access_token.ok_or_else(|| anyhow!("artifacts sync access token unavailable"))?;
        if config.base_url.trim().is_empty() {
            return Err(anyhow!("artifacts sync is enabled without baseUrl"));
        }
        Ok(Some(Self { config, token: Arc::from(token), client: http_client()? }))
    }

    pub fn enabled(&self) -> bool {
        self.config.enabled
    }

    pub async fn save_artifact(
        &self,
        title: &str,
        kind: &str,
        files: &[(String, Vec<u8>, Option<String>)],
        trailers: Trailers,
    ) -> Result<(String, String)> {
        let repo_response = self
            .client
            .post(self.url("/v1/artifacts/repo"))
            .bearer_auth(self.token.as_ref())
            .send()
            .await?;
        ensure_success(repo_response.status(), "artifact repo provision")?;
        let repo: RepoResponse =
            repo_response.json().await.context("decode artifact repo response")?;
        let expected_head_sha = repo.head_sha;
        let (inline, large): (Vec<_>, Vec<_>) =
            files.iter().cloned().partition(|(_, bytes, _)| bytes.len() <= BLOB_THRESHOLD);
        let payload = CreateArtifactRequest {
            title,
            kind,
            files: inline
                .iter()
                .map(|(name, bytes, content_type)| CreateArtifactFile {
                    name: name.clone(),
                    content_base64: BASE64.encode(bytes),
                    content_type: content_type.clone(),
                })
                .collect(),
            trailers: trailers.clone(),
            expected_head_sha,
        };
        let response = self
            .client
            .post(self.url("/v1/artifacts"))
            .bearer_auth(self.token.as_ref())
            .json(&payload)
            .send()
            .await?;
        ensure_success(response.status(), "artifact create")?;
        let value: serde_json::Value =
            response.json().await.context("decode artifact create response")?;
        let id = value
            .get("id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("artifact response missing id"))?
            .to_owned();
        let mut head = value
            .get("headSha")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("artifact response missing headSha"))?
            .to_owned();
        if !large.is_empty() {
            let mut changes = Vec::with_capacity(large.len());
            for (name, bytes, content_type) in large {
                let blob_response = self
                    .client
                    .post(self.url("/v1/artifacts/blobs"))
                    .bearer_auth(self.token.as_ref())
                    .body(bytes.clone())
                    .send()
                    .await?;
                ensure_success(blob_response.status(), "artifact blob upload")?;
                let blob: BlobResponse =
                    blob_response.json().await.context("decode artifact blob response")?;
                if blob.size != bytes.len() {
                    return Err(anyhow!("artifact blob response size mismatch"));
                }
                changes.push(Change {
                    path: format!("artifacts/{id}/{name}"),
                    op: "put",
                    content_base64: None,
                    blob_sha256: Some(blob.sha256),
                    content_type,
                });
            }
            let save = SaveRequest {
                expected_head_sha: Some(head),
                branch: "main",
                message: format!("Add large files to artifact {id}"),
                trailers,
                changes,
            };
            let save_response = self
                .client
                .post(self.url("/v1/artifacts/save"))
                .bearer_auth(self.token.as_ref())
                .json(&save)
                .send()
                .await?;
            ensure_success(save_response.status(), "artifact large-file save")?;
            let saved: SaveResponse =
                save_response.json().await.context("decode artifact large-file save response")?;
            head = saved.head_sha;
        }
        Ok((id, head))
    }

    pub async fn list(
        &self,
        prefix: Option<&str>,
        kind: Option<&str>,
    ) -> Result<serde_json::Value> {
        let query: Vec<_> = [("prefix", prefix), ("kind", kind)]
            .into_iter()
            .filter_map(|(key, value)| Some((key, value?)))
            .collect();
        let response = self
            .client
            .get(with_query(&self.url("/v1/artifacts"), &query)?)
            .bearer_auth(self.token.as_ref())
            .send()
            .await?;
        ensure_success(response.status(), "artifact list")?;
        Ok(response.json().await?)
    }

    pub async fn search(&self, query: &str, limit: usize) -> Result<serde_json::Value> {
        let limit_string = limit.to_string();
        let response = self
            .client
            .get(with_query(
                &self.url("/v1/artifacts/search"),
                &[("q", query), ("limit", limit_string.as_str())],
            )?)
            .bearer_auth(self.token.as_ref())
            .send()
            .await?;
        ensure_success(response.status(), "artifact search")?;
        Ok(response.json().await?)
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.config.base_url.trim_end_matches('/'), path)
    }
}
