export interface ClientTheme {
  background: string;
  foreground: string;
  palette: string[];
  opacity: number;
}

export function applyThemeVars(
  vars: Record<string, string>,
  theme?: ClientTheme,
  root: Pick<CSSStyleDeclaration, "setProperty"> = document.documentElement.style,
  search = location.search,
) {
  const next = { ...vars };
  if (theme) {
    const params = new URLSearchParams(search);
    const transparent = params.get("transparent") === "1";
    const override = parseFloat(params.get("opacity") ?? "");
    const opacity = transparent ? (Number.isNaN(override) ? theme.opacity : override) : 1;
    const n = parseInt(theme.background.slice(1), 16);
    const rgb = `${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}`;
    next["--bg"] = theme.background;
    next["--fg"] = theme.foreground;
    next["--bg-body"] = `rgba(${rgb}, ${opacity})`;
    next["--bg-html"] = transparent ? "transparent" : theme.background;
  }
  for (const [key, value] of Object.entries(next)) root.setProperty(key, value);
}
