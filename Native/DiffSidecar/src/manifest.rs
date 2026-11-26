use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AllowedFile {
    pub request_path: String,
    pub file_path: String,
    pub mime_type: String,
    pub remote_url: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Manifest {
    pub token: String,
    pub files: Vec<AllowedFile>,
}

impl Manifest {
    /// Loads and validates a token-bound manifest from the sidecar root.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid tokens, unreadable manifests, or invalid contents.
    pub async fn load(root: &Path, token: &str) -> Result<Self, String> {
        if !valid_token(token) {
            return Err("invalid token".to_owned());
        }
        let path = root.join(format!(".manifest-{token}.json"));
        let bytes = tokio::fs::read(path)
            .await
            .map_err(|error| error.to_string())?;
        let manifest: Self = serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
        if manifest.token != token || manifest.files.is_empty() || manifest.files.len() > 4096 {
            return Err("invalid manifest".to_owned());
        }
        Ok(manifest)
    }

    /// Validates entries and indexes them by request path.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid or duplicate manifest entries.
    pub fn files_by_path(&self) -> Result<HashMap<String, AllowedFile>, String> {
        let mut result = HashMap::with_capacity(self.files.len());
        for file in &self.files {
            file.validate()?;
            if result
                .insert(file.request_path.clone(), file.clone())
                .is_some()
            {
                return Err("duplicate manifest path".to_owned());
            }
        }
        Ok(result)
    }
}

impl AllowedFile {
    /// Validates the request path, MIME type, and remote-resource constraints.
    ///
    /// # Errors
    ///
    /// Returns an error when any manifest entry constraint is violated.
    pub fn validate(&self) -> Result<(), String> {
        if !valid_request_path(&self.request_path) || !valid_mime_type(&self.mime_type) {
            return Err("invalid manifest entry".to_owned());
        }
        if !path_matches_mime(&self.request_path, &self.mime_type) {
            return Err("manifest MIME mismatch".to_owned());
        }
        if self.remote_url.is_some()
            && (self.mime_type != "text/x-diff" || !self.file_path.is_empty())
        {
            return Err("invalid remote manifest entry".to_owned());
        }
        Ok(())
    }

    /// Resolves a local manifest entry without permitting escapes from `root`.
    ///
    /// # Errors
    ///
    /// Returns an error for remote entries, missing files, or paths outside `root`.
    pub async fn canonical_local_path(&self, root: &Path) -> Result<PathBuf, String> {
        if self.remote_url.is_some() || self.file_path.is_empty() {
            return Err("not a local file".to_owned());
        }
        let canonical_root = tokio::fs::canonicalize(root)
            .await
            .map_err(|error| error.to_string())?;
        let canonical_file = tokio::fs::canonicalize(&self.file_path)
            .await
            .map_err(|error| error.to_string())?;
        if !canonical_file.starts_with(&canonical_root) {
            return Err("manifest file escapes root".to_owned());
        }
        let metadata = tokio::fs::metadata(&canonical_file)
            .await
            .map_err(|error| error.to_string())?;
        if !metadata.is_file() {
            return Err("manifest entry is not a file".to_owned());
        }
        Ok(canonical_file)
    }
}

#[must_use]
pub fn split_resource_path(path: &str) -> Option<(&str, String)> {
    let trimmed = path.trim_start_matches('/');
    let (token, tail) = trimmed.split_once('/')?;
    if !valid_token(token) {
        return None;
    }
    let request_path = format!("/{tail}");
    valid_request_path(&request_path).then_some((token, request_path))
}

#[must_use]
pub fn valid_token(token: &str) -> bool {
    (16..=80).contains(&token.len())
        && token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

#[must_use]
pub fn valid_request_path(path: &str) -> bool {
    path.starts_with('/')
        && !path.contains('\\')
        && !path.contains("//")
        && path
            .split('/')
            .skip(1)
            .all(|component| !component.is_empty() && component != "." && component != "..")
}

fn valid_mime_type(mime_type: &str) -> bool {
    matches!(mime_type, "text/html" | "text/javascript" | "text/x-diff")
}

fn path_matches_mime(path: &str, mime_type: &str) -> bool {
    let extension = Path::new(path).extension().and_then(|value| value.to_str());
    match mime_type {
        "text/html" => extension.is_some_and(|value| value.eq_ignore_ascii_case("html")),
        "text/javascript" => extension.is_some_and(|value| {
            value.eq_ignore_ascii_case("js") || value.eq_ignore_ascii_case("mjs")
        }),
        "text/x-diff" => extension.is_some_and(|value| value.eq_ignore_ascii_case("patch")),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::{split_resource_path, valid_request_path, valid_token};

    #[test]
    fn token_and_path_validation_reject_traversal() {
        assert!(valid_token("0123456789abcdef"));
        assert!(!valid_token("short"));
        assert!(valid_request_path("/viewer/main.mjs"));
        assert!(!valid_request_path("/../secret"));
        assert!(!valid_request_path("/viewer//main.mjs"));
        assert!(split_resource_path("/0123456789abcdef/viewer.patch").is_some());
    }
}
