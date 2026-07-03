// Resolve the effective terminal background/foreground from the user's
// Ghostty config, the same file cmux's embedded terminal reads.
import { homedir } from "node:os";
import { existsSync, readFileSync } from "node:fs";

export interface GhosttyTheme {
  background: string; // #rrggbb
  foreground: string; // #rrggbb
  opacity: number; // background-opacity, 1 = opaque
  blur: number; // background-blur-radius
  isLight: boolean;
  themeName: string | null;
}

const THEME_DIRS = [
  `${homedir()}/.config/ghostty/themes`,
  "/Applications/cmux.app/Contents/Resources/ghostty/themes",
  "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
];

function parseKVs(text: string): Map<string, string> {
  // Last occurrence wins, matching Ghostty scalar semantics.
  const map = new Map<string, string>();
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1);
    map.set(key, value);
  }
  return map;
}

function normalizeColor(v: string | undefined): string | null {
  if (!v) return null;
  const m = v.trim().replace(/^#/, "");
  return /^[0-9a-fA-F]{6}$/.test(m) ? `#${m.toLowerCase()}` : null;
}

function themeColors(name: string): { bg: string | null; fg: string | null } {
  for (const dir of THEME_DIRS) {
    const path = `${dir}/${name}`;
    if (!existsSync(path)) continue;
    const kv = parseKVs(readFileSync(path, "utf8"));
    return { bg: normalizeColor(kv.get("background")), fg: normalizeColor(kv.get("foreground")) };
  }
  return { bg: null, fg: null };
}

function luminance(hex: string): number {
  const n = parseInt(hex.slice(1), 16);
  const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

export function resolveGhosttyTheme(): GhosttyTheme {
  let bg: string | null = null;
  let fg: string | null = null;
  let opacity = 1;
  let blur = 0;
  let themeName: string | null = null;

  try {
    const kv = parseKVs(readFileSync(`${homedir()}/.config/ghostty/config`, "utf8"));
    themeName = kv.get("theme") ?? null;
    if (themeName) {
      // `theme = light:X,dark:Y` — cmux UI is dark-first; prefer the dark
      // variant when split, else the single name.
      const variants = Object.fromEntries(
        themeName.split(",").map((part) => {
          const [k, ...rest] = part.split(":");
          return rest.length ? [k.trim(), rest.join(":").trim()] : ["single", part.trim()];
        }),
      );
      const chosen = variants.single ?? variants.dark ?? variants.light;
      if (chosen) {
        themeName = chosen;
        const colors = themeColors(chosen);
        bg = colors.bg;
        fg = colors.fg;
      }
    }
    // Explicit keys in the user config override the theme.
    bg = normalizeColor(kv.get("background")) ?? bg;
    fg = normalizeColor(kv.get("foreground")) ?? fg;
    const op = parseFloat(kv.get("background-opacity") ?? "");
    if (!Number.isNaN(op) && op > 0 && op <= 1) opacity = op;
    const bl = parseFloat(kv.get("background-blur-radius") ?? kv.get("background-blur") ?? "");
    if (!Number.isNaN(bl)) blur = bl;
  } catch {
    // no ghostty config; fall through to defaults
  }

  bg ??= "#101014";
  fg ??= "#e8e8ec";
  return { background: bg, foreground: fg, opacity, blur, isLight: luminance(bg) > 0.5, themeName };
}
