//! Ownership-reservation prerelease for `cmux-sidebar`.
//!
//! Use a stable release for the Ratatui integration.

/// Identifies this package as the one-time ownership bootstrap.
pub const OWNERSHIP_BOOTSTRAP: bool = true;

#[cfg(test)]
mod tests {
    #[test]
    fn identifies_the_ownership_bootstrap() {
        assert!(super::OWNERSHIP_BOOTSTRAP);
    }
}
