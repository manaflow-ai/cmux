import { applyThemeVars } from "../src/theme";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const written = new Map<string, string>();
const style = {
  setProperty(key: string, value: string) {
    written.set(key, value);
  },
};

applyThemeVars(
  {
    "--font-mono": "\"Cascadia Code\", monospace",
    "--accent": "#0000ff",
  },
  { background: "#102030", foreground: "#eeeeee", palette: [], opacity: 0.5 },
  style,
  "?transparent=1&opacity=0.25",
);

assert(written.get("--font-mono") === "\"Cascadia Code\", monospace", "client theme apply should write server-resolved font vars");
assert(written.get("--accent") === "#0000ff", "client theme apply should write server-resolved color vars");
assert(written.get("--bg") === "#102030", "client theme apply should write the new background");
assert(written.get("--bg-body") === "rgba(16, 32, 48, 0.25)", `client theme apply should respect transparent opacity override: ${written.get("--bg-body")}`);
assert(written.get("--bg-html") === "transparent", "client theme apply should preserve transparent html mode");
