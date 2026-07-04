// Resolve the effective terminal background/foreground the same way cmux's
// embedded terminal does: ask ghostty itself (`+show-config` prints the fully
// resolved config, including theme-file colors and repeated-key semantics).
// Falls back to hand-parsing ~/.config/ghostty/config when no ghostty binary
// is available.
import { homedir } from "node:os";
import { existsSync, readFileSync } from "node:fs";

export interface GhosttyTheme {
  background: string; // #rrggbb
  foreground: string; // #rrggbb
  opacity: number; // background-opacity, 1 = opaque
  blur: number; // background-blur-radius
  isLight: boolean;
  source: string;
}

const GHOSTTY_BINS = [
  process.env.CMUX_GHOSTTY_BIN ?? "",
  "/Applications/cmux.app/Contents/Resources/bin/ghostty",
  "/Applications/Ghostty.app/Contents/MacOS/ghostty",
].filter(Boolean);

const THEME_DIRS = [
  `${homedir()}/.config/ghostty/themes`,
  "/Applications/cmux.app/Contents/Resources/ghostty/themes",
  "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
];

let cached: { theme: GhosttyTheme; at: number } | null = null;

export function resolveGhosttyTheme(): GhosttyTheme {
  if (cached && Date.now() - cached.at < 3000) return cached.theme;
  const theme = fromShowConfig() ?? fromManualParse();
  cached = { theme, at: Date.now() };
  return theme;
}

function fromShowConfig(): GhosttyTheme | null {
  for (const bin of GHOSTTY_BINS) {
    if (!existsSync(bin)) continue;
    try {
      const res = Bun.spawnSync([bin, "+show-config"], { stdout: "pipe", stderr: "ignore", env: { ...process.env } });
      if (res.exitCode !== 0) continue;
      const kv = parseKVs(res.stdout.toString());
      const bg = normalizeColor(kv.get("background"));
      const fg = normalizeColor(kv.get("foreground"));
      if (!bg || !fg) continue;
      return finish(bg, fg, kv, `show-config:${bin}`);
    } catch {
      // try the next binary
    }
  }
  return null;
}

function fromManualParse(): GhosttyTheme {
  let bg: string | null = null;
  let fg: string | null = null;
  let kv = new Map<string, string>();
  try {
    const text = readFileSync(`${homedir()}/.config/ghostty/config`, "utf8");
    kv = parseKVs(text);
    // Ghostty resolves the FIRST theme line (verified against +show-config).
    const themeLine = text
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l.startsWith("theme"))
      ?.split("=")[1];
    const themeName = themeLine ? unquote(themeLine.trim()) : null;
    if (themeName) {
      const single = themeName.includes(":")
        ? Object.fromEntries(themeName.split(",").map((p) => p.split(":").map((s) => s.trim()) as [string, string])).dark
        : themeName;
      if (single) {
        const colors = themeColors(single);
        bg = colors.bg;
        fg = colors.fg;
      }
    }
    bg = normalizeColor(kv.get("background")) ?? bg;
    fg = normalizeColor(kv.get("foreground")) ?? fg;
  } catch {
    // no ghostty config at all; use defaults
  }
  return finish(bg ?? "#101014", fg ?? "#e8e8ec", kv, "manual-parse");
}

function finish(bg: string, fg: string, kv: Map<string, string>, source: string): GhosttyTheme {
  const op = parseFloat(kv.get("background-opacity") ?? "");
  const bl = parseFloat(kv.get("background-blur-radius") ?? kv.get("background-blur") ?? "");
  return {
    background: bg,
    foreground: fg,
    opacity: !Number.isNaN(op) && op > 0 && op <= 1 ? op : 1,
    blur: Number.isNaN(bl) ? 0 : bl,
    isLight: luminance(bg) > 0.5,
    source,
  };
}

function parseKVs(text: string): Map<string, string> {
  const map = new Map<string, string>();
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    map.set(line.slice(0, eq).trim(), unquote(line.slice(eq + 1).trim()));
  }
  return map;
}

function unquote(v: string): string {
  return v.startsWith('"') && v.endsWith('"') ? v.slice(1, -1) : v;
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
