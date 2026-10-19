//! Who this host serves, decided on the WhoIs answer for the peer address.
//!
//! Default deny. Order: the deny list, then the node's owner, then the
//! allow list, then (only when turned on) any member of the tailnet. Tagged
//! devices have no owner, so they never pass as the owner; they pass only by
//! an explicit `tag:` entry in the allow list.

use crate::{Status, WhoIs};

#[derive(Debug, Clone, Default)]
pub struct Access {
    /// Principals that are always refused (`user:<login>` or `tag:<name>`).
    pub deny: Vec<String>,
    /// Principals served in addition to the owner.
    pub allow: Vec<String>,
    /// Serve every user device that the tailnet's ACLs let through (never tagged devices).
    pub allow_tailnet_members: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Allow { principal: String, why: &'static str },
    Deny { principal: String, why: &'static str },
}

impl Decision {
    pub fn allowed(&self) -> bool {
        matches!(self, Self::Allow { .. })
    }
}

impl Access {
    pub fn check(&self, me: &Status, peer: &WhoIs) -> Decision {
        let principal = peer.principal();
        let names = principals(peer);
        if names.iter().any(|name| self.deny.contains(name)) {
            return Decision::Deny { principal, why: "on the deny list" };
        }
        let Some(user) = peer.user_profile.as_ref().filter(|_| !peer.is_tagged()) else {
            if names.iter().any(|name| self.allow.contains(name)) {
                return Decision::Allow { principal, why: "tag on the allow list" };
            }
            return Decision::Deny { principal, why: "tagged or unidentified device" };
        };
        if me.owner().is_some_and(|owner| owner.id != 0 && owner.id == user.id) {
            return Decision::Allow { principal, why: "owner" };
        }
        if names.iter().any(|name| self.allow.contains(name)) {
            return Decision::Allow { principal, why: "on the allow list" };
        }
        if self.allow_tailnet_members {
            return Decision::Allow { principal, why: "tailnet member" };
        }
        Decision::Deny { principal, why: "not the owner" }
    }
}

fn principals(peer: &WhoIs) -> Vec<String> {
    let mut names: Vec<String> = peer.tags().to_vec();
    if let Some(user) = &peer.user_profile
        && !user.login_name.is_empty()
    {
        names.push(format!("user:{}", user.login_name));
    }
    names
}
