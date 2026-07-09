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
  palette: string[]; // ANSI 0-15, #rrggbb
  selectionBackground: string | null;
  cursorColor: string | null;
  fontFamily: string | null;
  fontSize: number | null;
  opacity: number; // background-opacity, 1 = opaque
  blur: number; // background-blur-radius
  isLight: boolean;
  accent?: string | null;
  source: string;
  sources: string[];
}

export const DEFAULT_ANSI_PALETTE = [
  "#1d1f21",
  "#cc6666",
  "#b5bd68",
  "#f0c674",
  "#81a2be",
  "#b294bb",
  "#8abeb7",
  "#c5c8c6",
  "#666666",
  "#d54e53",
  "#b9ca4a",
  "#e7c547",
  "#7aa6da",
  "#c397d8",
  "#70c0b1",
  "#eaeaea",
] as const;

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

const MANAGED_CONFIGS = [
  `${homedir()}/Library/Application Support/com.mitchellh.ghostty/config`,
  `${homedir()}/Library/Application Support/com.cmuxterm.app/config.ghostty`,
];

let cached: { theme: GhosttyTheme; at: number } | null = null;

export function resolveGhosttyTheme(force = false): GhosttyTheme {
  if (force) cached = null;
  if (cached && Date.now() - cached.at < 3000) return cached.theme;
  const theme = fromShowConfig() ?? fromManualParse();
  cached = { theme, at: Date.now() };
  return theme;
}

export async function resolveGhosttyThemeAsync(force = false): Promise<GhosttyTheme> {
  if (force) cached = null;
  if (cached && Date.now() - cached.at < 3000) return cached.theme;
  const theme = await fromShowConfigAsync() ?? fromManualParse();
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
      const managed = applyManagedThemeOverrides(kv, macAppearanceSync());
      const mergedBg = normalizeColor(managed.kv.get("background")) ?? bg;
      const mergedFg = normalizeColor(managed.kv.get("foreground")) ?? fg;
      return finish(mergedBg, mergedFg, managed.kv, `show-config:${bin}`, ghosttySourceFiles(managed.sources));
    } catch {
      // try the next binary
    }
  }
  return null;
}

async function fromShowConfigAsync(): Promise<GhosttyTheme | null> {
  for (const bin of GHOSTTY_BINS) {
    if (!existsSync(bin)) continue;
    try {
      const proc = Bun.spawn([bin, "+show-config"], { stdout: "pipe", stderr: "ignore", env: { ...process.env } });
      const [text, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
      if (code !== 0) continue;
      const kv = parseKVs(text);
      const bg = normalizeColor(kv.get("background"));
      const fg = normalizeColor(kv.get("foreground"));
      if (!bg || !fg) continue;
      const managed = applyManagedThemeOverrides(kv, await macAppearanceAsync());
      const mergedBg = normalizeColor(managed.kv.get("background")) ?? bg;
      const mergedFg = normalizeColor(managed.kv.get("foreground")) ?? fg;
      return finish(mergedBg, mergedFg, managed.kv, `show-config:${bin}`, ghosttySourceFiles(managed.sources));
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
  let sources: string[] = [];
  try {
    const text = readFileSync(`${homedir()}/.config/ghostty/config`, "utf8");
    kv = parseKVs(text);
    // Ghostty resolves repeated keys with the last value winning.
    const themeName = lastThemeName(text, macAppearanceSync());
    if (themeName) {
      const theme = themeKVs(themeName);
      if (theme) {
        kv = new Map([...theme, ...kv]);
        bg = normalizeColor(kv.get("background"));
        fg = normalizeColor(kv.get("foreground"));
      }
    }
  } catch {
    // no ghostty config at all; use defaults
  }
  const managed = applyManagedThemeOverrides(kv, macAppearanceSync());
  kv = managed.kv;
  sources = managed.sources;
  bg = normalizeColor(kv.get("background")) ?? bg;
  fg = normalizeColor(kv.get("foreground")) ?? fg;
  return finish(bg ?? "#101014", fg ?? "#e8e8ec", kv, "manual-parse", ghosttySourceFiles(sources));
}

function finish(bg: string, fg: string, kv: Map<string, string>, source: string, sources: string[]): GhosttyTheme {
  const op = parseFloat(kv.get("background-opacity") ?? "");
  const bl = parseFloat(kv.get("background-blur-radius") ?? kv.get("background-blur") ?? "");
  const palette = DEFAULT_ANSI_PALETTE.map((fallback, i) => normalizeColor(kv.get(`palette.${i}`)) ?? fallback);
  return {
    background: bg,
    foreground: fg,
    palette,
    selectionBackground: normalizeColor(kv.get("selection-background")),
    cursorColor: normalizeColor(kv.get("cursor-color")),
    fontFamily: parseFontFamily(kv.get("font-family")),
    fontSize: parseFontSize(kv.get("font-size")),
    opacity: !Number.isNaN(op) && op > 0 && op <= 1 ? op : 1,
    blur: Number.isNaN(bl) ? 0 : bl,
    isLight: luminance(bg) > 0.5,
    accent: normalizeColor(kv.get("agent-chat-accent")),
    source,
    sources,
  };
}

export function pickAccentColor(theme: Pick<GhosttyTheme, "foreground" | "palette" | "accent">): string {
  if (theme.accent) return theme.accent;
  for (const slot of [4, 12, 6, 14, 5, 13, 2, 10]) {
    const color = theme.palette[slot];
    if (!color) continue;
    const { hue, saturation } = hsl(color);
    if (saturation >= 0.22 && hue >= 180 && hue <= 290) return color;
  }
  return theme.foreground;
}

function parseKVs(text: string): Map<string, string> {
  const map = new Map<string, string>();
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    const value = unquote(line.slice(eq + 1).trim());
    if (key === "palette") {
      const m = /^(\d{1,2})\s*=\s*(#[0-9a-fA-F]{6}|[0-9a-fA-F]{6})$/.exec(value);
      if (m) {
        const idx = Number(m[1]);
        const color = normalizeColor(m[2]);
        if (idx >= 0 && idx <= 15 && color) map.set(`palette.${idx}`, color);
      }
    }
    map.set(key, value);
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

function parseFontFamily(v: string | undefined): string | null {
  const s = v?.trim();
  return s ? s : null;
}

function parseFontSize(v: string | undefined): number | null {
  if (!v) return null;
  const n = parseFloat(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function themeKVs(name: string): Map<string, string> | null {
  for (const dir of THEME_DIRS) {
    const path = `${dir}/${name}`;
    if (!existsSync(path)) continue;
    return parseKVs(readFileSync(path, "utf8"));
  }
  return null;
}

export function ghosttyConfigPath(): string {
  return `${homedir()}/.config/ghostty/config`;
}

function ghosttySourceFiles(extra: string[] = []): string[] {
  const files = new Set<string>([ghosttyConfigPath()]);
  for (const file of MANAGED_CONFIGS) files.add(file);
  for (const file of extra) files.add(file);
  try {
    const text = readFileSync(ghosttyConfigPath(), "utf8");
    for (const raw of text.split("\n")) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const eq = line.indexOf("=");
      if (eq < 0 || line.slice(0, eq).trim() !== "theme") continue;
      const value = resolveThemeValue(unquote(line.slice(eq + 1).trim()), macAppearanceSync());
      for (const name of themeNames(value)) {
        const file = themeFilePath(name);
        if (file) files.add(file);
      }
    }
  } catch {
    // no config to watch beyond the default path
  }
  return [...files];
}

function themeNames(value: string): string[] {
  if (!value) return [];
  if (!value.includes(":")) return [value];
  return value
    .split(",")
    .map((part) => part.split(":")[1]?.trim())
    .filter((v): v is string => Boolean(v));
}

function lastThemeName(text: string, appearance: "light" | "dark"): string | null {
  let value: string | null = null;
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0 || line.slice(0, eq).trim() !== "theme") continue;
    value = resolveThemeValue(unquote(line.slice(eq + 1).trim()), appearance);
  }
  return value;
}

function resolveThemeValue(value: string, appearance: "light" | "dark"): string {
  if (!value.includes(":")) return value;
  const pairs = Object.fromEntries(value.split(",").map((p) => p.split(":").map((s) => s.trim()) as [string, string]));
  return pairs[appearance] ?? pairs.dark ?? pairs.light ?? value;
}

function applyManagedThemeOverrides(kv: Map<string, string>, appearance: "light" | "dark"): { kv: Map<string, string>; sources: string[] } {
  let next = kv;
  const sources: string[] = [];
  for (const file of MANAGED_CONFIGS) {
    sources.push(file);
    if (!existsSync(file)) continue;
    try {
      const name = lastThemeName(readFileSync(file, "utf8"), appearance);
      if (!name) continue;
      const theme = themeKVs(name);
      const themeFile = themeFilePath(name);
      if (themeFile) sources.push(themeFile);
      if (theme) next = new Map([...next, ...theme]);
    } catch {
      // Ignore malformed managed config files; base Ghostty config remains valid.
    }
  }
  return { kv: next, sources };
}

function macAppearanceSync(): "light" | "dark" {
  try {
    const res = Bun.spawnSync(["defaults", "read", "-g", "AppleInterfaceStyle"], { stdout: "pipe", stderr: "ignore", env: { ...process.env } });
    return res.exitCode === 0 && /dark/i.test(res.stdout.toString()) ? "dark" : "light";
  } catch {
    return "light";
  }
}

async function macAppearanceAsync(): Promise<"light" | "dark"> {
  try {
    const proc = Bun.spawn(["defaults", "read", "-g", "AppleInterfaceStyle"], { stdout: "pipe", stderr: "ignore", env: { ...process.env } });
    const [text, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
    return code === 0 && /dark/i.test(text) ? "dark" : "light";
  } catch {
    return "light";
  }
}

export function resolveThemeNameForTest(text: string, appearance: "light" | "dark"): string | null {
  return lastThemeName(text, appearance);
}

export function applyManagedThemeOverrideForTest(kv: Map<string, string>, themeKv: Map<string, string>): Map<string, string> {
  return new Map([...kv, ...themeKv]);
}

function themeFilePath(name: string): string | null {
  for (const dir of THEME_DIRS) {
    const path = `${dir}/${name}`;
    if (existsSync(path)) return path;
  }
  return null;
}

function luminance(hex: string): number {
  const n = parseInt(hex.slice(1), 16);
  const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

function hsl(hex: string): { hue: number; saturation: number; lightness: number } {
  const n = parseInt(hex.slice(1), 16);
  const r = ((n >> 16) & 255) / 255;
  const g = ((n >> 8) & 255) / 255;
  const b = (n & 255) / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const lightness = (max + min) / 2;
  const delta = max - min;
  if (delta === 0) return { hue: 0, saturation: 0, lightness };
  const saturation = delta / (1 - Math.abs(2 * lightness - 1));
  let hue = 0;
  if (max === r) hue = ((g - b) / delta) % 6;
  else if (max === g) hue = (b - r) / delta + 2;
  else hue = (r - g) / delta + 4;
  hue *= 60;
  if (hue < 0) hue += 360;
  return { hue, saturation, lightness };
}
