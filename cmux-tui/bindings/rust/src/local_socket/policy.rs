//! The same-user rules as pure functions over identities, so they are
//! tested on every platform and with fake values the OS cannot produce
//! (another user, an AppContainer) without extra accounts.

/// The Medium mandatory level's RID (`SECURITY_MANDATORY_MEDIUM_RID`): the
/// level of a normal user process. Low (0x1000) and Untrusted (0) are
/// sandboxes.
pub const MEDIUM_INTEGRITY_RID: u32 = 0x2000;

/// What the OS says about the process at the other end of a socket.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PeerIdentity {
    /// The token user, as a string SID (`S-1-5-21-...`).
    pub user_sid: String,
    /// The token's mandatory integrity RID (`TokenIntegrityLevel`).
    pub integrity_rid: u32,
    /// `TokenIsAppContainer`.
    pub app_container: bool,
}

/// Why a peer or a socket file is refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Another user (another SID, SYSTEM or Administrators included).
    OtherUser(String),
    /// The same user, sandboxed below Medium integrity.
    LowIntegrity(u32),
    /// The same user, in an AppContainer.
    AppContainer,
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::OtherUser(sid) => {
                write!(f, "refused: owned by or running as another user ({sid})")
            }
            Self::LowIntegrity(rid) => {
                write!(f, "refused: a sandboxed peer (integrity {rid:#x}, below Medium)")
            }
            Self::AppContainer => write!(f, "refused: a peer in an AppContainer"),
        }
    }
}

/// A peer may connect when it runs as our user, at Medium integrity or
/// above, outside any AppContainer.
pub fn peer_allowed(peer: &PeerIdentity, our_user_sid: &str) -> Result<(), Refusal> {
    owner_allowed(&peer.user_sid, our_user_sid)?;
    if peer.app_container {
        return Err(Refusal::AppContainer);
    }
    if peer.integrity_rid < MEDIUM_INTEGRITY_RID {
        return Err(Refusal::LowIntegrity(peer.integrity_rid));
    }
    Ok(())
}

/// A socket file (or its directory) is ours when its owner is our token
/// user, exactly (not a group such as BUILTIN\Administrators).
pub fn owner_allowed(owner_sid: &str, our_user_sid: &str) -> Result<(), Refusal> {
    // String SIDs are case-insensitive only in their "S" prefix; the
    // numbers are decimal, so an ASCII case-insensitive comparison is exact.
    if owner_sid.eq_ignore_ascii_case(our_user_sid) {
        Ok(())
    } else {
        Err(Refusal::OtherUser(owner_sid.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ME: &str = "S-1-5-21-1-2-3-1002";

    fn peer(user: &str, rid: u32, app_container: bool) -> PeerIdentity {
        PeerIdentity { user_sid: user.into(), integrity_rid: rid, app_container }
    }

    #[test]
    fn same_user_at_medium_or_high_is_admitted() {
        assert_eq!(peer_allowed(&peer(ME, 0x2000, false), ME), Ok(()));
        assert_eq!(peer_allowed(&peer(ME, 0x2100, false), ME), Ok(()));
        assert_eq!(peer_allowed(&peer(ME, 0x3000, false), ME), Ok(()));
    }

    #[test]
    fn another_user_is_refused() {
        let other = "S-1-5-21-1-2-3-1003";
        assert_eq!(
            peer_allowed(&peer(other, 0x2000, false), ME),
            Err(Refusal::OtherUser(other.into()))
        );
        // SYSTEM and the Administrators group are other principals too.
        for sid in ["S-1-5-18", "S-1-5-32-544", "S-1-5-19"] {
            assert_eq!(
                peer_allowed(&peer(sid, 0x4000, false), ME),
                Err(Refusal::OtherUser(sid.into()))
            );
        }
    }

    #[test]
    fn sandboxed_same_user_is_refused() {
        assert_eq!(peer_allowed(&peer(ME, 0x1000, false), ME), Err(Refusal::LowIntegrity(0x1000)));
        assert_eq!(peer_allowed(&peer(ME, 0, false), ME), Err(Refusal::LowIntegrity(0)));
        assert_eq!(peer_allowed(&peer(ME, 0x2000, true), ME), Err(Refusal::AppContainer));
    }

    #[test]
    fn sids_compare_case_insensitively_but_exactly() {
        assert_eq!(peer_allowed(&peer("s-1-5-21-1-2-3-1002", 0x2000, false), ME), Ok(()));
        assert!(peer_allowed(&peer("S-1-5-21-1-2-3-10020", 0x2000, false), ME).is_err());
    }

    #[test]
    fn owner_must_be_our_user_not_a_group() {
        assert_eq!(owner_allowed(ME, ME), Ok(()));
        assert_eq!(
            owner_allowed("S-1-5-32-544", ME),
            Err(Refusal::OtherUser("S-1-5-32-544".into()))
        );
        assert!(owner_allowed("S-1-5-21-1-2-3-1003", ME).is_err());
    }
}
