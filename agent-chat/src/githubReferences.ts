// Bare GitHub references in the chat transcript.
//
// Agents write `#847`, `owner/repo#847`, `GH-1234` and abbreviated commit SHAs
// far more often than they write a URL, and the terminal already makes all four
// clickable. This is the same reading applied to the transcript, so the same
// sentence behaves the same way in both panes.
//
// The rules mirror TerminalGitHubReferenceDetector in CmuxTerminalCore,
// including the parts that refuse: a bare number needs a known repository, a
// hex run needs both a digit and a letter, and checksum lengths are not
// commits. A false positive here is worse than a missed link, because it sends
// a reader to a page that has nothing to do with what they clicked.

/// Characters stripped from the front of a token before matching.
const LEADING_TRIM = new Set("([{<'\"`*_");
/// Characters stripped from the end of a token before matching.
const TRAILING_TRIM = new Set(")]}>'\"`*_,.;:!?");
/// Abbreviated SHAs only. 40 is what `sha1sum` prints and 32 is what `md5sum`
/// prints, so those lengths would turn checksum output into a link to a commit
/// that does not exist.
const SHA_MIN_LENGTH = 7;
const SHA_MAX_LENGTH = 12;
/// GitHub issue numbers stay well inside nine digits.
const MAX_ISSUE_NUMBER_DIGITS = 9;

/// A GitHub issue, pull request, or commit that a token names without a URL.
export interface GitHubReference {
  /// GitHub redirects `/issues/<n>` to the pull request when the number is one,
  /// so both read as `issue`.
  kind: "issue" | "commit";
  /// The `owner/name` repository the reference resolves against.
  repositorySlug: string;
  /// The token as it was written, after punctuation trimming.
  rawToken: string;
  /// The `github.com` URL for the reference.
  url: string;
}

/// The reference a single token names, or `null`.
///
/// `repositorySlug` is the session's repository, used for references that do
/// not name one. Pass `null` when the session has no GitHub remote; a bare
/// `#847` then stays text rather than guessing a repository.
export function gitHubReference(token: string, repositorySlug: string | null): GitHubReference | null {
  const trimmed = trimWrappingPunctuation(token);
  if (!trimmed) return null;

  // Anything carrying a scheme belongs to the markdown autolinker. Reading a
  // `#123` fragment out of a URL would send the click somewhere else entirely.
  if (trimmed.includes("://")) return null;

  const hashIndex = trimmed.indexOf("#");
  if (hashIndex >= 0) {
    const owner = trimmed.slice(0, hashIndex);
    const number = issueNumber(trimmed.slice(hashIndex + 1));
    if (number === null) return null;
    const slug = owner ? normalizedSlug(owner) : normalizedSlug(repositorySlug);
    if (!slug) return null;
    return issue(slug, number, trimmed);
  }

  const dashNumber = gitHubDashNumber(trimmed);
  if (dashNumber !== null) {
    const slug = normalizedSlug(repositorySlug);
    return slug ? issue(slug, dashNumber, trimmed) : null;
  }

  if (isCommitSHA(trimmed)) {
    const slug = normalizedSlug(repositorySlug);
    if (!slug) return null;
    return { kind: "commit", repositorySlug: slug, rawToken: trimmed, url: `https://github.com/${slug}/commit/${trimmed}` };
  }

  return null;
}

/// Rewrites bare GitHub references in markdown source into markdown links.
///
/// This runs before the transcript parses the markdown, so the renderer itself
/// is untouched and a reference ends up as an ordinary link with the transcript's
/// own link handling. Code spans, fenced blocks, existing links and autolinks are
/// left exactly as written: in those places the characters are the content.
export function linkifyGitHubReferences(markdown: string, repositorySlug: string | null): string {
  let output = "";
  let index = 0;
  for (const match of markdown.matchAll(PROTECTED_SPAN)) {
    const start = match.index ?? 0;
    output += linkifyProse(markdown.slice(index, start), repositorySlug);
    output += match[0];
    index = start + match[0].length;
  }
  return output + linkifyProse(markdown.slice(index), repositorySlug);
}

/// Spans whose contents are never rewritten, in the order they win:
/// fenced code, inline code, images and links, then autolinks.
const PROTECTED_SPAN =
  /```[\s\S]*?(?:```|$)|`[^`\n]*`|!?\[[^\]\n]*\]\([^)\n]*\)|<[^>\s]+>/g;

/// Rewrites references in a run of ordinary prose.
function linkifyProse(text: string, repositorySlug: string | null): string {
  if (!text) return text;
  // Splitting on whitespace and keeping it is what makes a token here the same
  // token the terminal detector sees, so the two surfaces agree on boundaries.
  return text
    .split(/(\s+)/)
    .map((token) => {
      if (!token.trim()) return token;
      const { leading, core, trailing } = splitWrappingPunctuation(token);
      if (!core) return token;
      const reference = gitHubReference(core, repositorySlug);
      if (!reference) return token;
      return `${leading}[${core}](${reference.url})${trailing}`;
    })
    .join("");
}

/// Builds an issue or pull request reference.
function issue(slug: string, number: number, rawToken: string): GitHubReference {
  return { kind: "issue", repositorySlug: slug, rawToken, url: `https://github.com/${slug}/issues/${number}` };
}

/// The token with wrapping quotes, brackets and sentence punctuation removed.
function trimWrappingPunctuation(token: string): string {
  return splitWrappingPunctuation(token).core;
}

/// The token split into the punctuation around it and the candidate inside.
function splitWrappingPunctuation(token: string): { leading: string; core: string; trailing: string } {
  let start = 0;
  while (start < token.length && LEADING_TRIM.has(token[start])) start += 1;
  let end = token.length;
  while (end > start && TRAILING_TRIM.has(token[end - 1])) end -= 1;
  return { leading: token.slice(0, start), core: token.slice(start, end), trailing: token.slice(end) };
}

/// The issue number a digit run names, rejecting zero, leading zeros, and runs
/// too long to be a number GitHub hands out.
function issueNumber(text: string): number | null {
  if (!text || text.length > MAX_ISSUE_NUMBER_DIGITS) return null;
  if (!/^[0-9]+$/.test(text)) return null;
  if (text[0] === "0") return null;
  const value = Number(text);
  return value > 0 ? value : null;
}

/// The issue number in the `GH-1234` form changelogs and commit trailers use.
function gitHubDashNumber(token: string): number | null {
  if (token.slice(0, 3).toLowerCase() !== "gh-") return null;
  return issueNumber(token.slice(3));
}

/// Whether a token reads as an abbreviated commit SHA.
///
/// Requires both a digit and a letter. A hex run that is all digits is far more
/// likely to be an ordinary number, and one that is all letters is far more
/// likely to be a word such as `deadbeef`. That drops a small share of genuine
/// short SHAs in exchange for not sending clicks on numbers and words to GitHub.
function isCommitSHA(token: string): boolean {
  if (token.length < SHA_MIN_LENGTH || token.length > SHA_MAX_LENGTH) return false;
  let sawDigit = false;
  let sawLetter = false;
  for (const character of token) {
    if (character >= "0" && character <= "9") sawDigit = true;
    else if (character >= "a" && character <= "f") sawLetter = true;
    else return false;
  }
  return sawDigit && sawLetter;
}

/// The `owner/name` slug a candidate names, dropping a trailing `.git`.
function normalizedSlug(candidate: string | null): string | null {
  if (!candidate) return null;
  const components = candidate.split("/");
  if (components.length !== 2) return null;
  const owner = components[0];
  const name = components[1].endsWith(".git") ? components[1].slice(0, -4) : components[1];
  if (!isSlugComponent(owner) || !isSlugComponent(name)) return null;
  return `${owner}/${name}`;
}

/// Whether a component matches what GitHub allows in an owner or repository name.
function isSlugComponent(component: string): boolean {
  if (!component || component.length > 100) return false;
  if (component === "." || component === "..") return false;
  return /^[A-Za-z0-9._-]+$/.test(component);
}

/// The `owner/name` slug a git remote URL names, or `null`.
///
/// Only `github.com` is accepted. A self-hosted GitHub Enterprise host spells
/// issue URLs against its own domain, so assuming github.com would send every
/// click on that machine to a stranger's repository.
export function gitHubSlugFromRemoteURL(remoteURL: string): string | null {
  const trimmed = remoteURL.trim();
  if (!trimmed) return null;

  // `git@github.com:owner/name.git` is not a URL, so it is matched directly
  // rather than through the URL parser.
  const scpLike = /^[^@/\s]+@([^:/\s]+):(.+)$/.exec(trimmed);
  if (scpLike) {
    return scpLike[1] === "github.com" ? normalizedSlug(stripGitSuffix(scpLike[2])) : null;
  }

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return null;
  }
  if (parsed.hostname !== "github.com") return null;
  return normalizedSlug(stripGitSuffix(parsed.pathname.replace(/^\/+/, "")));
}

/// The path without a trailing `.git` or slash.
function stripGitSuffix(path: string): string {
  const withoutSlash = path.replace(/\/+$/, "");
  return withoutSlash.endsWith(".git") ? withoutSlash.slice(0, -4) : withoutSlash;
}
