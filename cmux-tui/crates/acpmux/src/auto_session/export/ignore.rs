//! The default ignore set for a folder that is no git checkout (security review of
//! cmux#52931, item 3). Such a folder has no `.gitignore`, so without this every file the
//! name-based secrets rule (`cmux_git::secrets`) does not name went to the Cloud: other
//! version control stores, dependency trees, and the folders and files tools keep logins in.
//! A checkout is untouched: git's own ignore rules decide there.

use std::path::Path;

/// Folders never entered: version control stores, dependency trees, credential stores.
const DIRS: &[&str] = &[
    ".git",
    ".hg",
    ".svn",
    ".bzr",
    "_darcs",
    "CVS",
    ".jj",
    ".pijul",
    "node_modules",
    ".ssh",
    ".gnupg",
    ".aws",
    ".azure",
    ".docker",
    ".kube",
    ".password-store",
    ".terraform",
];

/// Files left behind by their whole name: logins and tokens tools write.
const FILES: &[&str] = &[
    ".git-credentials",
    "credentials.json",
    "credentials",
    ".pgpass",
    ".my.cnf",
    ".htpasswd",
    "terraform.tfstate",
    "terraform.tfstate.backup",
    "secrets.json",
    "secrets.yml",
    "secrets.yaml",
    ".vault-token",
];

/// Files left behind by their ending: key stores, password databases, encrypted keys.
const ENDINGS: &[&str] =
    &[".jks", ".keystore", ".kdbx", ".kdb", ".gpg", ".ppk", ".p8", ".ovpn", ".tfvars", ".tfstate"];

/// Whether `name`, the last part of a path, stays behind: a folder when `is_dir`. `.env`
/// files are named here too, though the secrets rule also catches them.
pub(super) fn ignored(name: &Path, is_dir: bool) -> bool {
    let name = name.to_string_lossy();
    if is_dir {
        return DIRS.contains(&name.as_ref());
    }
    let lower = name.to_ascii_lowercase();
    name.starts_with(".env")
        || FILES.contains(&lower.as_str())
        || ENDINGS.iter().any(|ending| lower.ends_with(ending))
}
