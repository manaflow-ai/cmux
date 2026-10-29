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

/// The markdown nodes this plugin reads and writes.
///
/// Only the handful of fields the walk touches are named, so the transcript
/// does not take a dependency on the mdast type packages for four properties.
interface MarkdownNode {
  type: string;
  value?: string;
  children?: MarkdownNode[];
  url?: string;
  position?: { end?: { offset?: number } };
}

/// Node types whose text is content rather than prose, so nothing inside them
/// is rewritten.
///
/// `code` and `inlineCode` hold characters the author asked to see verbatim.
/// `link`, `linkReference` and `definition` already point somewhere, and
/// turning part of their text into a second link would nest one link inside
/// another. `html` is passed through untouched by the renderer.
///
/// The parser has already decided which of these each run of characters
/// belongs to, which is the whole reason this is a tree walk rather than a
/// search over the markdown source: a source-level guess has to re-derive the
/// fence, span and escape rules, and it gets them wrong for `~~~` blocks,
/// indented blocks, double-backtick spans and spans that wrap a line.
const OPAQUE_NODE_TYPES = new Set(["code", "inlineCode", "link", "linkReference", "definition", "html", "imageReference", "image", "yaml"]);

/// How the transcript resolves bare references.
export interface GitHubReferenceOptions {
  /// The session's repository, used for references that do not name one.
  repositorySlug: string | null;
  /// Whether the message is still arriving.
  ///
  /// A number that is still being typed is a prefix of the number the agent
  /// means, so `#8471` passes through `#8`, `#84` and `#847` on its way in, and
  /// each of those is a link to a different issue that someone can click during
  /// a pause. While a message streams, the token at the very end of it is left
  /// as text until something follows it.
  streaming?: boolean;
}

/// A remark plugin that turns bare GitHub references into links.
///
/// It runs on the parsed document rather than on the markdown source, so code
/// spans, code blocks, existing links and autolinks are skipped because the
/// parser has already put them in their own nodes.
///
/// Goes in a plugin list the way remark takes options, as
/// `[remarkGitHubReferences, options]`: remark calls the plugin itself with the
/// options and keeps what it returns as the transform.
export function remarkGitHubReferences(options: GitHubReferenceOptions) {
  return function transform(tree: MarkdownNode, file: unknown): void {
    const sourceLength = String(file as { toString(): string }).length;
    visit(tree, options, options.streaming === true ? sourceLength : null);
  };
}

/// Rewrites every prose text node under `node`.
function visit(node: MarkdownNode, options: GitHubReferenceOptions, protectedEndOffset: number | null): void {
  const children = node.children;
  if (!children) return;
  let index = 0;
  while (index < children.length) {
    const child = children[index];
    if (OPAQUE_NODE_TYPES.has(child.type)) {
      index += 1;
      continue;
    }
    if (child.type !== "text") {
      visit(child, options, protectedEndOffset);
      index += 1;
      continue;
    }
    const endsDocument = protectedEndOffset !== null && child.position?.end?.offset === protectedEndOffset;
    const replacement = referenceNodes(child.value ?? "", options.repositorySlug, endsDocument);
    if (!replacement) {
      index += 1;
      continue;
    }
    children.splice(index, 1, ...replacement);
    index += replacement.length;
  }
}

/// The nodes a run of prose becomes, or `null` when it holds no reference.
///
/// `holdFinalToken` leaves the last token alone, for the end of a message that
/// is still streaming.
export function referenceNodes(value: string, repositorySlug: string | null, holdFinalToken = false): MarkdownNode[] | null {
  // Splitting on whitespace and keeping it is what makes a token here the same
  // token the terminal detector sees, so the two surfaces agree on boundaries.
  const parts = value.split(/(\s+)/);
  const lastTokenIndex = lastNonEmptyIndex(parts);
  const nodes: MarkdownNode[] = [];
  let pending = "";
  let linked = false;

  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    const held = holdFinalToken && index === lastTokenIndex;
    const reference = part.trim() && !held ? referenceInToken(part, repositorySlug) : null;
    if (!reference) {
      pending += part;
      continue;
    }
    if (pending || reference.leading) nodes.push({ type: "text", value: pending + reference.leading });
    nodes.push({ type: "link", url: reference.url, children: [{ type: "text", value: reference.core }] });
    pending = reference.trailing;
    linked = true;
  }

  if (!linked) return null;
  if (pending) nodes.push({ type: "text", value: pending });
  return nodes;
}

/// The index of the last part that is not whitespace, or `-1`.
function lastNonEmptyIndex(parts: string[]): number {
  for (let index = parts.length - 1; index >= 0; index -= 1) {
    if (parts[index].trim()) return index;
  }
  return -1;
}

/// The reference a whitespace-delimited token names, with the punctuation that
/// wrapped it kept aside so it stays outside the link.
function referenceInToken(token: string, repositorySlug: string | null): { leading: string; core: string; trailing: string; url: string } | null {
  const { leading, core, trailing } = splitWrappingPunctuation(token);
  if (!core) return null;
  const reference = gitHubReference(core, repositorySlug);
  return reference ? { leading, core, trailing, url: reference.url } : null;
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
    // Host comparison is case-insensitive here because the `URL` parser lowers
    // the host on the other branch, and a remote written `git@GitHub.com:` is
    // the same host as one written in lower case.
    return scpLike[1].toLowerCase() === "github.com" ? normalizedSlug(stripGitSuffix(scpLike[2])) : null;
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
