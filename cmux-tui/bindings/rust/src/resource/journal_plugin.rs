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
const MAX_PERMISSION_COUNT: usize = 32;
const MAX_PERMISSION_BYTES: usize = 128;
const MAX_EVENTS: usize = 64;
const MAX_SUBJECT_COUNT: usize = 64;
const MAX_SUBJECT_ID_BYTES: usize = 512;
const MAX_CAUSAL_ID_BYTES: usize = 128;
const MAX_MANIFEST_BYTES: usize = 1024 * 1024;
const MAX_EVENT_ID_BYTES: usize = 128;

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

fn valid_decimal(value: &str) -> bool {
    if value.is_empty() || value.starts_with('+') || (value.starts_with('0') && value.len() > 1) {
        return false;
    }
    value.bytes().all(|byte| byte.is_ascii_digit()) && value.parse::<u64>().is_ok()
}

fn valid_event_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_EVENT_ID_BYTES
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
        if self.permissions.is_empty() || self.permissions.len() > MAX_PERMISSION_COUNT {
            return Err(Error::InvalidArgument(format!(
                "permissions must contain 1 to {MAX_PERMISSION_COUNT} entries"
            )));
        }
        if self
            .permissions
            .iter()
            .any(|permission| permission.is_empty() || permission.len() > MAX_PERMISSION_BYTES)
        {
            return Err(Error::InvalidArgument(format!(
                "permissions must contain 1 to {MAX_PERMISSION_BYTES} bytes"
            )));
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
        let namespace_prefix = format!("plugin.{}.", self.producer_id);
        if !valid_component(&self.producer_id)
            || self.manifest_version == 0
            || self.schema_version == 0
            || !valid_kind(&self.kind)
            || !self.kind.starts_with(&namespace_prefix)
            || self.subjects.len() > MAX_SUBJECT_COUNT
            || self.subjects.iter().any(|subject| {
                !valid_component(&subject.kind)
                    || subject.id.is_empty()
                    || subject.id.len() > MAX_SUBJECT_ID_BYTES
            })
        {
            return Err(Error::InvalidArgument("journal event envelope is invalid".into()));
        }
        if self.sensitivity == Some(JournalSensitivity::Secret) {
            return Err(Error::InvalidArgument(
                "secret journal payload storage is unavailable".into(),
            ));
        }
        if self
            .causation_id
            .as_ref()
            .is_some_and(|value| value.is_empty() || value.len() > MAX_CAUSAL_ID_BYTES)
            || self
                .correlation_id
                .as_ref()
                .is_some_and(|value| value.is_empty() || value.len() > MAX_CAUSAL_ID_BYTES)
        {
            return Err(Error::InvalidArgument(format!(
                "causation_id and correlation_id must contain 1 to {MAX_CAUSAL_ID_BYTES} bytes"
            )));
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

impl JournalProducerPutResult {
    /// Validate a mutation receipt before exposing server data to a plugin.
    pub fn validate(&self) -> Result<()> {
        if !valid_component(&self.producer_id)
            || self.manifest_version == 0
            || self.namespace != format!("plugin.{}", self.producer_id)
            || !valid_decimal(&self.sequence)
            || !valid_event_id(&self.event_id)
        {
            return Err(Error::Decode("invalid journal producer mutation result".into()));
        }
        Ok(())
    }
}

/// Result returned by `session.journal.producer.list`.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalProducerListResult {
    pub producers: Vec<JournalProducerManifest>,
}

impl JournalProducerListResult {
    /// Validate a server response before exposing it to a plugin.
    pub fn validate(&self) -> Result<()> {
        const MAX_PRODUCERS: usize = 1024;
        if self.producers.len() > MAX_PRODUCERS {
            return Err(Error::Decode(format!(
                "journal producer list contains more than {MAX_PRODUCERS} entries"
            )));
        }
        for producer in &self.producers {
            producer.validate().map_err(|error| {
                Error::Decode(format!("invalid journal producer manifest: {error}"))
            })?;
        }
        Ok(())
    }
}

/// Receipt returned by `session.journal.append`.
#[derive(Clone, Debug, PartialEq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalAppendResult {
    pub producer_id: String,
    pub sequence: String,
    pub event_id: String,
}

impl JournalAppendResult {
    /// Validate a mutation receipt before exposing server data to a plugin.
    pub fn validate(&self) -> Result<()> {
        if !valid_component(&self.producer_id)
            || !valid_decimal(&self.sequence)
            || !valid_event_id(&self.event_id)
        {
            return Err(Error::Decode("invalid journal append result".into()));
        }
        Ok(())
    }
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

    #[test]
    fn producer_and_ingress_limits_are_checked_before_socket_io() {
        let mut producer = manifest("screen-detector");
        producer.permissions =
            vec!["journal.append.plugin.screen-detector".into(); MAX_PERMISSION_COUNT + 1];
        assert!(producer.validate().is_err());

        let mut event = JournalIngress {
            producer_id: "screen-detector".into(),
            manifest_version: 1,
            kind: "plugin.screen-detector.agent.state.changed".into(),
            schema_version: 1,
            occurred_at_ms: None,
            subjects: vec![JournalSubject {
                kind: "terminal".into(),
                id: "x".repeat(MAX_SUBJECT_ID_BYTES + 1),
            }],
            sensitivity: None,
            payload: serde_json::json!({}),
            causation_id: Some("c".repeat(MAX_CAUSAL_ID_BYTES + 1)),
            correlation_id: None,
        };
        assert!(event.validate().is_err());
        event.subjects[0].id = "x".repeat(MAX_SUBJECT_ID_BYTES);
        event.causation_id = Some("c".repeat(MAX_CAUSAL_ID_BYTES));
        assert!(event.validate().is_ok());

        event.kind = "agent.state.changed".into();
        assert!(event.validate().is_err());
    }

    #[test]
    fn mutation_receipts_reject_invalid_identity_and_sequence() {
        let mut put = JournalProducerPutResult {
            producer_id: "screen-detector".into(),
            manifest_version: 1,
            namespace: "plugin.screen-detector".into(),
            sequence: "1".into(),
            event_id: "event-1".into(),
        };
        assert!(put.validate().is_ok());
        put.namespace = "agent".into();
        assert!(put.validate().is_err());

        let append = JournalAppendResult {
            producer_id: "screen-detector".into(),
            sequence: "01".into(),
            event_id: "event-1".into(),
        };
        assert!(append.validate().is_err());
    }
}
