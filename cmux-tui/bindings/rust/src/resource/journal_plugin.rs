//! Typed request models for userland journal producers.
//!
//! These are generic journal contracts. The `AgentPlugin*` names below are
//! compatibility aliases for early SDK users. A plugin is not a special
//! journal writer, and adding a new plugin must not require a core type.

use super::typed_stream::{JournalClass, JournalReplayPolicy, JournalSensitivity, JournalSubject};
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

const MAX_COMPONENT_BYTES: usize = 64;
const MAX_KIND_BYTES: usize = 128;
const MAX_EVENTS: usize = 64;
const MAX_MANIFEST_BYTES: usize = 1024 * 1024;

fn valid_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_COMPONENT_BYTES
        && value.as_bytes().first().is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_' || byte == b'-'
        })
}

fn valid_kind(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_KIND_BYTES && value.split('.').all(valid_component)
}

fn sensitivity_rank(value: JournalSensitivity) -> u8 {
    match value {
        JournalSensitivity::Public => 0,
        JournalSensitivity::Metadata => 1,
        JournalSensitivity::Sensitive => 2,
        JournalSensitivity::Secret => 3,
    }
}

fn serialize_optional_decimal<S>(
    value: &Option<u64>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    match value {
        Some(value) => serializer.serialize_some(&value.to_string()),
        None => serializer.serialize_none(),
    }
}

/// One event schema declared by a journal producer.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalEventSchema {
    pub kind: String,
    pub schema_version: u32,
    pub class: JournalClass,
    pub replay: JournalReplayPolicy,
    pub sensitivity: JournalSensitivity,
    pub payload_schema: Value,
}

/// Manifest installed by a userland journal producer.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalProducerManifest {
    pub producer_id: String,
    pub namespace: String,
    pub manifest_version: u32,
    pub max_sensitivity: JournalSensitivity,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub permissions: Vec<String>,
    pub events: Vec<JournalEventSchema>,
}

impl JournalProducerManifest {
    /// Validate the same structural and authority rules checked by the
    /// daemon. The daemon remains authoritative because it also compiles the
    /// JSON schemas inside its transaction.
    pub fn validate(&self) -> Result<()> {
        if !valid_component(&self.producer_id) {
            return Err(Error::InvalidArgument(
                "producer_id must match [a-z0-9][a-z0-9_-]* and contain at most 64 bytes".into(),
            ));
        }
        if self.namespace != format!("plugin.{}", self.producer_id) {
            return Err(Error::InvalidArgument(
                "journal producer namespace must be plugin.<producer_id>".into(),
            ));
        }
        if self.manifest_version == 0 || self.events.is_empty() || self.events.len() > MAX_EVENTS {
            return Err(Error::InvalidArgument(format!(
                "manifest_version must be positive and events must contain 1 to {MAX_EVENTS} entries"
            )));
        }
        if self.max_sensitivity == JournalSensitivity::Secret {
            return Err(Error::InvalidArgument(
                "secret journal payload storage is unavailable".into(),
            ));
        }
        if !self
            .permissions
            .iter()
            .any(|permission| permission == &format!("journal.append.{}", self.namespace))
        {
            return Err(Error::InvalidArgument(
                "journal producer manifest requires its journal append permission".into(),
            ));
        }
        let encoded = serde_json::to_vec(self)
            .map_err(|error| Error::Decode(format!("serialize journal manifest: {error}")))?;
        if encoded.len() > MAX_MANIFEST_BYTES {
            return Err(Error::InvalidArgument(format!(
                "journal producer manifest exceeds {MAX_MANIFEST_BYTES} bytes"
            )));
        }
        let namespace_prefix = format!("{}.", self.namespace);
        let mut identities = BTreeSet::new();
        for event in &self.events {
            if !valid_kind(&event.kind) || !event.kind.starts_with(&namespace_prefix) {
                return Err(Error::InvalidArgument(
                    "journal event kind must be a dotted lowercase name inside the producer namespace"
                        .into(),
                ));
            }
            if event.schema_version == 0 {
                return Err(Error::InvalidArgument(
                    "journal event schema_version must be positive".into(),
                ));
            }
            if event.sensitivity == JournalSensitivity::Secret
                || sensitivity_rank(event.sensitivity) > sensitivity_rank(self.max_sensitivity)
            {
                return Err(Error::InvalidArgument(
                    "journal event sensitivity exceeds producer authority".into(),
                ));
            }
            if !identities.insert((&event.kind, event.schema_version)) {
                return Err(Error::InvalidArgument(
                    "journal producer declares a duplicate event schema".into(),
                ));
            }
        }
        Ok(())
    }
}

/// Generic journal ingress envelope for a userland producer.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct JournalIngress {
    pub producer_id: String,
    pub manifest_version: u32,
    pub kind: String,
    pub schema_version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(serialize_with = "serialize_optional_decimal")]
    pub occurred_at_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub subjects: Vec<JournalSubject>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sensitivity: Option<JournalSensitivity>,
    pub payload: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub causation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub correlation_id: Option<String>,
}

impl JournalIngress {
    /// Validate the envelope before it crosses the socket. The selected
    /// producer manifest remains the authority for schema and sensitivity.
    pub fn validate(&self) -> Result<()> {
        if !valid_component(&self.producer_id)
            || self.manifest_version == 0
            || self.schema_version == 0
            || !valid_kind(&self.kind)
            || self
                .subjects
                .iter()
                .any(|subject| !valid_component(&subject.kind) || subject.id.is_empty())
        {
            return Err(Error::InvalidArgument("journal event envelope is invalid".into()));
        }
        if self.sensitivity == Some(JournalSensitivity::Secret) {
            return Err(Error::InvalidArgument(
                "secret journal payload storage is unavailable".into(),
            ));
        }
        Ok(())
    }
}

/// Receipt returned by `session.journal.producer.put`.
#[derive(Clone, Debug, PartialEq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalProducerPutResult {
    pub producer_id: String,
    pub manifest_version: u32,
    pub namespace: String,
    pub sequence: String,
    pub event_id: String,
}

/// Result returned by `session.journal.producer.list`.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalProducerListResult {
    pub producers: Vec<JournalProducerManifest>,
}

/// Receipt returned by `session.journal.append`.
#[derive(Clone, Debug, PartialEq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalAppendResult {
    pub producer_id: String,
    pub sequence: String,
    pub event_id: String,
}

// Compatibility names from the first agent-plugin preview. Keep them as
// aliases so plugins do not need a coordinated SDK upgrade.
pub type AgentPluginEventSchema = JournalEventSchema;
pub type AgentPluginManifest = JournalProducerManifest;
pub type AgentPluginSubject = JournalSubject;
pub type AgentPluginIngress = JournalIngress;
pub type AgentPluginListResult = JournalProducerListResult;
pub type JournalEventSubject = JournalSubject;

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(producer_id: &str) -> JournalProducerManifest {
        JournalProducerManifest {
            producer_id: producer_id.into(),
            namespace: format!("plugin.{producer_id}"),
            manifest_version: 1,
            max_sensitivity: JournalSensitivity::Sensitive,
            permissions: vec![format!("journal.append.plugin.{producer_id}")],
            events: vec![JournalEventSchema {
                kind: format!("plugin.{producer_id}.state.changed"),
                schema_version: 1,
                class: JournalClass::State,
                replay: JournalReplayPolicy::Required,
                sensitivity: JournalSensitivity::Sensitive,
                payload_schema: serde_json::json!({"type":"object"}),
            }],
        }
    }

    #[test]
    fn producer_component_grammar_is_shared_with_core() {
        assert!(manifest("screen-detector").validate().is_ok());
        assert!(manifest("screen_detector").validate().is_ok());
        assert!(manifest("_screen-detector").validate().is_err());
        assert!(manifest("Screen-detector").validate().is_err());
    }
}
