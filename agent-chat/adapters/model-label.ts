const FAMILY_PREFIXES = new Map([
  ["gpt", "GPT"],
  ["glm", "GLM"],
]);

function isSlugShaped(value: string): boolean {
  return /^[a-z0-9.-]+(?:-[a-z0-9.-]+)*$/i.test(value);
}

function prettyToken(token: string): string {
  const lower = token.toLowerCase();
  const family = FAMILY_PREFIXES.get(lower);
  if (family) return family;
  if (/^\d+(?:\.\d+)*$/.test(token)) return token;
  return lower ? lower[0]!.toUpperCase() + lower.slice(1) : token;
}

export function prettifyModelLabel(labelOrSlug: string): string {
  const raw = String(labelOrSlug || "").trim();
  if (!raw || !isSlugShaped(raw)) return raw;
  const parts = raw.split("-").filter(Boolean);
  if (!parts.length) return raw;
  if (parts.length >= 2 && /^[a-z]+$/i.test(parts[0]!) && /^\d/.test(parts[1]!)) {
    const head = `${prettyToken(parts[0]!)}-${parts[1]}`;
    const rest = parts.slice(2).map(prettyToken);
    return [head, ...rest].join(" ");
  }
  return parts.map(prettyToken).join(" ");
}

export function prettifyProviderModelLabel(provider: string, model: string, label?: string): string {
  const modelLabel = prettifyModelLabel(label || model);
  return `${provider}/${modelLabel}`;
}
