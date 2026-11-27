//! Which device opens a web link the person opens on the phone (a link in a
//! terminal, which the Mac's shell printed): the shared classifier of
//! `cmux_local_url::side`, which the Mac's daemon reads too (a link a program
//! opens while the phone drives its terminal, `offer-link-to-phone`).

use cmux_local_url::side::{LinkSide, link_side};

/// Where a web link opened on the phone goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkOpenSide {
    /// A public address: the phone's own browser.
    Phone,
    /// An address only the Mac can reach: a browser tab on the Mac.
    Mac,
    /// Not a web page (`javascript:`, `file:`, an app's scheme, no host).
    NotWeb,
}

impl From<LinkSide> for LinkOpenSide {
    fn from(side: LinkSide) -> Self {
        match side {
            LinkSide::Phone => Self::Phone,
            LinkSide::Mac => Self::Mac,
            LinkSide::NotWeb => Self::NotWeb,
        }
    }
}

/// Which device opens `url`, a link the person opened on the phone.
#[uniffi::export]
pub fn link_open_side(url: String) -> LinkOpenSide {
    link_side(&url).into()
}

#[cfg(test)]
mod tests {
    use super::{LinkOpenSide, link_open_side};

    /// The phone reads the daemon's classifier (its table: cmux-local-url `side.rs`).
    #[test]
    fn the_phone_reads_the_shared_classifier() {
        assert_eq!(link_open_side("https://github.com/login".into()), LinkOpenSide::Phone);
        assert_eq!(link_open_side("http://localhost:3000/".into()), LinkOpenSide::Mac);
        assert_eq!(link_open_side("javascript:alert(1)".into()), LinkOpenSide::NotWeb);
    }
}
