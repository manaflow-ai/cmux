use super::super::id::MachineId;
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

/// Origin of a machine visible to cmux.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MachineOrigin {
    Local,
    Cloud,
    Ssh,
    Server,
}

/// Current lifecycle state of a machine.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MachineStatus {
    Running,
    Connecting,
    Sleeping,
    Stopped,
    Unavailable,
}

/// Non-secret owner platform metadata; missing fields remain unknown.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct MachinePlatform {
    pub os: Option<String>,
    pub arch: Option<String>,
}

/// Catalog snapshot for one machine.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct MachineSnapshot {
    pub id: MachineId,
    pub name: String,
    pub origin: MachineOrigin,
    pub status: MachineStatus,
    pub connectable: bool,
    pub deleted: bool,
    pub recoverable: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
    #[serde(default)]
    pub platform: Option<MachinePlatform>,
    #[serde(default)]
    pub capabilities: Vec<String>,
}

#[cfg(test)]
#[path = "model_machine_tests.rs"]
mod tests;
