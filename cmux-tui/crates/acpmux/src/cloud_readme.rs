//! `~/README.md` on a cmux Cloud machine: what the machine is and how an agent on it gets more
//! capacity (`cmux machine request`).
//!
//! Leo, 2026-11-25: "but what if we want even more than the 32vcpu machines? how can an agent
//! know/ask for more capacity?" and "when they're on the vm that is". cmuxterm-hq RFD draft
//! `docs/rfd/drafts/agent-work-placement.md`, sections 9 and 13.
//!
//! The daemon writes it as the work user once the Cloud agent's socket is up
//! (`daemon/cloud_activity.rs`), so it ships with the binary and needs no image rebake. It
//! writes only a missing file or one that starts with [`MARK`] (its own); a README the person or
//! an agent wrote stays as it is.

use std::path::Path;

/// The first line of the file this module owns.
pub const MARK: &str =
    "<!-- cmux Cloud machine README: written by cmux; delete this line to keep your own edits -->";

/// The file's text.
pub fn text() -> String {
    format!(
        "{MARK}\n\
# This is a cmux Cloud machine

A Linux VM that runs your cmux agents. `nproc` and `free -g` show its size now.

## Need more capacity?

Ask for it from here; the machine speaks for itself, no sign-in:

```
cmux machine request --vcpu 16 --for \"cargo build of the workspace\"
cmux machine request --vcpu 32 --mem 64 --for \"test suite\" --until 2h --json
```

Agents can call the `machine_request` tool (acpmux MCP) instead. The answer comes at once:

- `fits`: this machine already has it.
- `grow`: it grows now, within your plan, and keeps running.
- `over_plan`: past your plan; the answer names the largest size the plan takes and what lifts it.
- `fanout`: past one machine (32 vCPU / 64 GiB is the largest): K machines are made now. The
  answer is their handle with each machine's id; `cmux vm exec ID -- CMD` runs work on one.
  64 cores is 2 x 2xl: `cmux machine request --vcpu 64 --for \"build farm\" --until 2h`.
- `unavailable`: a kind (mac, gpu) Cloud does not offer yet.

Sizes: sm 2/4, md 4/8, lg 8/16, lgx 12/24, xl 16/32, 2xl 32/64 (vCPU / GiB).
`cmux machine request --help` has the rest.
"
    )
}

/// Writes `home/README.md` when it is missing or still ours and out of date. `Ok(true)` when it
/// wrote.
pub fn ensure(home: &Path) -> std::io::Result<bool> {
    let path = home.join("README.md");
    let want = text();
    match std::fs::symlink_metadata(&path) {
        Ok(meta) if !meta.is_file() => return Ok(false),
        Ok(_) => {
            let now = std::fs::read_to_string(&path).unwrap_or_default();
            if now == want || !now.starts_with(MARK) {
                return Ok(false);
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let temp = home.join(".README.md.cmux-tmp");
    crate::home_fs::write(&temp, &want)?;
    crate::home_fs::rename(&temp, &path)?;
    Ok(true)
}

#[cfg(test)]
#[path = "cloud_readme_tests.rs"]
mod tests;
