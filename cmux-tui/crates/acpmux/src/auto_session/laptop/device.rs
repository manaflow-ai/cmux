//! This laptop's id as a holder (`device:<id>`): made once and kept in the daemon's home, so
//! the store knows the same laptop after a restart.

use std::path::Path;

use anyhow::{Context, Result};

/// The file in the daemon's home that keeps the id.
const FILE: &str = "auto-device-id";

/// The longest id the store takes.
const ID_MAX: usize = 64;

/// The store takes letters, digits, `_ . -`.
fn taken(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= ID_MAX
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
}

/// The id kept in `home`, made and written when there is none the store takes.
fn id_in(home: &Path) -> Result<String> {
    let file = home.join(FILE);
    if let Ok(text) = std::fs::read_to_string(&file) {
        let kept = text.trim();
        if taken(kept) {
            return Ok(kept.to_owned());
        }
    }
    let id = uuid::Uuid::now_v7().to_string();
    crate::config::write_atomic(&file, id.as_bytes())
        .with_context(|| format!("writing {}", file.display()))?;
    Ok(id)
}

/// This laptop's device id. Blocking: it reads, and once writes, a small file.
pub(super) fn id() -> Result<String> {
    id_in(&crate::config::home())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_id_is_made_once_and_kept() {
        let home = tempfile::tempdir().unwrap();
        let first = id_in(home.path()).unwrap();
        assert!(taken(&first));
        assert_eq!(id_in(home.path()).unwrap(), first);
    }

    #[test]
    fn an_id_the_store_refuses_is_replaced() {
        let home = tempfile::tempdir().unwrap();
        std::fs::write(home.path().join(FILE), "not an id\n").unwrap();
        let id = id_in(home.path()).unwrap();
        assert!(taken(&id));
        assert_eq!(std::fs::read_to_string(home.path().join(FILE)).unwrap().trim(), id);
    }
}
