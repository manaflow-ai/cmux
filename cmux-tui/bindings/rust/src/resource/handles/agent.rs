//! Agent handles: read one agent row of the session.

use super::*;

impl Agent {
    pub fn selector(&self) -> &Selector<AgentId> {
        &self.selector
    }

    pub fn refresh(&self) -> Result<AgentSnapshot> {
        let id = id_selector(&self.selector, "agent")?;
        wire::list::<AgentSnapshot>(
            &self.session.client.read(ops::AGENT_LIST, self.session.params())?,
            "agents",
            "agent",
        )?
        .into_iter()
        .find(|snapshot| &snapshot.id == id)
        .ok_or_else(|| not_found("agent", id))
    }
}
