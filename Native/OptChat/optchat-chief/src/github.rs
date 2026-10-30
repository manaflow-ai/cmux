//! `optchat-chief github status|login|wait|pat|mac|logout|token`: a607's
//! verbs, kept word for word, over the GitHub tool pack
//! (`toolpacks/github/pack.toml`, toolpacks.rs; plans/cmux-next/chief-toolpacks-DESIGN.md).
//! `pat` is `pack paste github`, `mac` is `pack share github`.

use std::path::Path;

pub const USAGE: &str = "optchat-chief github status | login | wait [SECONDS] | pat FILE|- | mac | logout | token [--json] [--mux-home DIR]";

/// The `pack` words for `github VERB ARGS...`.
pub fn pack_words(words: &[String]) -> Result<Vec<String>, String> {
    let verb = words.get(1).map_or("status", String::as_str);
    let verb = match verb {
        "status" | "login" | "wait" | "logout" | "token" | "poll" => verb,
        "pat" => "paste",
        "mac" => "share",
        _ => return Err(USAGE.into()),
    };
    let mut out = vec!["pack".to_owned(), verb.to_owned(), "github".to_owned()];
    out.extend(words.iter().skip(2).cloned());
    Ok(out)
}

/// `optchat-chief github ...`.
pub fn run(flags: &crate::cli::Flags, home: &Path, as_json: bool) -> Result<String, String> {
    let mut flags = flags.clone();
    flags.words = pack_words(&flags.words)?;
    crate::toolpacks::run(&flags, home, as_json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_verbs_map_onto_the_pack() {
        let w = |v: &[&str]| pack_words(&v.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!(w(&["github"]).unwrap(), ["pack", "status", "github"]);
        assert_eq!(
            w(&["github", "pat", "-"]).unwrap(),
            ["pack", "paste", "github", "-"]
        );
        assert_eq!(w(&["github", "mac"]).unwrap(), ["pack", "share", "github"]);
        assert_eq!(
            w(&["github", "wait", "60"]).unwrap(),
            ["pack", "wait", "github", "60"]
        );
        assert!(w(&["github", "nope"]).is_err());
    }
}
