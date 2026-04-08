use std::collections::HashMap;
use std::time::Instant;

use serde::Serialize;

/// Unique identifier for a registered agent.
pub type AgentId = u64;

/// Resource snapshot for a running agent process.
#[derive(Debug, Clone, Serialize)]
pub struct ResourceUsage {
    /// CPU time consumed in seconds (user + system).
    pub cpu_secs: f64,
    /// Resident set size in bytes.
    pub rss_bytes: u64,
}

/// A registered agent process.
#[derive(Debug, Clone)]
pub struct AgentEntry {
    pub id: AgentId,
    pub name: String,
    pub pid: u32,
    pub started_at: Instant,
    pub last_usage: Option<ResourceUsage>,
}

impl AgentEntry {
    /// How long this agent has been running.
    pub fn uptime(&self) -> std::time::Duration {
        self.started_at.elapsed()
    }
}

/// Tracks all spawned agent processes.
#[derive(Debug, Default)]
pub struct Registry {
    agents: HashMap<AgentId, AgentEntry>,
    next_id: AgentId,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a new agent process. Returns its assigned ID.
    pub fn register(&mut self, name: String, pid: u32) -> AgentId {
        let id = self.next_id;
        self.next_id += 1;

        let entry = AgentEntry {
            id,
            name,
            pid,
            started_at: Instant::now(),
            last_usage: None,
        };

        self.agents.insert(id, entry);
        tracing::info!(id, pid, "agent registered");
        id
    }

    /// Remove an agent from the registry.
    pub fn deregister(&mut self, id: AgentId) -> Option<AgentEntry> {
        let entry = self.agents.remove(&id);
        if entry.is_some() {
            tracing::info!(id, "agent deregistered");
        }
        entry
    }

    /// Look up an agent by ID.
    pub fn get(&self, id: AgentId) -> Option<&AgentEntry> {
        self.agents.get(&id)
    }

    /// Mutable access to an agent (e.g., to update resource usage).
    pub fn get_mut(&mut self, id: AgentId) -> Option<&mut AgentEntry> {
        self.agents.get_mut(&id)
    }

    /// All registered agents.
    pub fn all(&self) -> impl Iterator<Item = &AgentEntry> {
        self.agents.values()
    }

    /// Number of registered agents.
    #[must_use]
    pub fn len(&self) -> usize {
        self.agents.len()
    }

    /// Whether the registry is empty.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.agents.is_empty()
    }

    /// Find agent by PID.
    #[must_use]
    pub fn find_by_pid(&self, pid: u32) -> Option<&AgentEntry> {
        self.agents.values().find(|a| a.pid == pid)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_and_lookup() {
        let mut reg = Registry::new();
        let id = reg.register("test-agent".to_string(), 1234);
        assert_eq!(reg.len(), 1);

        let entry = reg.get(id).unwrap();
        assert_eq!(entry.name, "test-agent");
        assert_eq!(entry.pid, 1234);
    }

    #[test]
    fn deregister_removes_entry() {
        let mut reg = Registry::new();
        let id = reg.register("agent".to_string(), 100);
        assert!(!reg.is_empty());

        let removed = reg.deregister(id);
        assert!(removed.is_some());
        assert!(reg.is_empty());
        assert!(reg.get(id).is_none());
    }

    #[test]
    fn ids_are_unique() {
        let mut reg = Registry::new();
        let id1 = reg.register("a".to_string(), 1);
        let id2 = reg.register("b".to_string(), 2);
        assert_ne!(id1, id2);
    }

    #[test]
    fn find_by_pid_works() {
        let mut reg = Registry::new();
        reg.register("alpha".to_string(), 42);
        reg.register("beta".to_string(), 99);

        let found = reg.find_by_pid(99).unwrap();
        assert_eq!(found.name, "beta");
        assert!(reg.find_by_pid(0).is_none());
    }

    #[test]
    fn update_resource_usage() {
        let mut reg = Registry::new();
        let id = reg.register("agent".to_string(), 10);

        let entry = reg.get_mut(id).unwrap();
        entry.last_usage = Some(ResourceUsage {
            cpu_secs: 5.2,
            rss_bytes: 100_000_000,
        });

        let entry = reg.get(id).unwrap();
        let usage = entry.last_usage.as_ref().unwrap();
        assert!((usage.cpu_secs - 5.2).abs() < f64::EPSILON);
        assert_eq!(usage.rss_bytes, 100_000_000);
    }
}
