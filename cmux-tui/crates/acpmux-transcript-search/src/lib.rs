//! Full-text search over the Claude Code and Codex transcripts on a machine, for `acpmux search`
//! (Leo, 2026-11-18: "shouldn't you be able to like have better tools for finding stuff?").
//!
//! A raw grep over a transcript cannot do it well: a 542 MB Claude Code transcript took a plain
//! grep past 120 s, a phrase with a line break or a quote in it is JSON-escaped in the file, and
//! the hit is one enormous line. This reads each transcript once into an index ([`Index`]) of what
//! was said in it, unescaped, and then only the bytes each one appends: a search catches up the
//! transcripts it covers (cost: what they wrote since) and asks the index.

pub mod index;
pub mod locate;
pub mod parse;
pub mod read;

pub use index::{CatchUp, EXACT_DOCS, Error, Hit, Index, Order, Page, Query, Result};
pub use locate::{Roots, Source};
pub use parse::{Harness, Role};

/// What one [`search`] did, besides its hits.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Searched {
    /// The transcripts it covered.
    pub files: u64,
    /// What reading them since the last search took.
    pub caught_up: CatchUp,
    pub catch_up_ms: u64,
    pub query_ms: u64,
    /// How many docs in the search's scope hold its text ([`Page::total`]).
    pub total: Option<u64>,
}

/// Catches up `sources` (the transcripts `q` covers) and finds `q` in them.
pub fn search(index: &Index, sources: &[Source], q: &Query) -> Result<(Vec<Hit>, Searched)> {
    let started = std::time::Instant::now();
    let mut done = Searched { files: sources.len() as u64, ..Searched::default() };
    for source in sources {
        let step = index.catch_up(source)?;
        done.caught_up.bytes += step.bytes;
        done.caught_up.docs += step.docs;
        done.caught_up.reread |= step.reread;
    }
    done.catch_up_ms = started.elapsed().as_millis() as u64;
    let asked = std::time::Instant::now();
    let page = index.page(q)?;
    done.total = page.total;
    done.query_ms = asked.elapsed().as_millis() as u64;
    Ok((page.hits, done))
}

#[cfg(test)]
mod tests;
