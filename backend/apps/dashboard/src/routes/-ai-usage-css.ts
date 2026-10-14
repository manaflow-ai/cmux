/**
 * Styles of the AI usage view (-ai-usage-view.tsx), scoped by the `aiu-` prefix. UI board rules
 * (.cmux-scratch/ui-evolve/board/PRINCIPLES.md): large title and one muted sentence; quiet hierarchy
 * with no blue (primary = light fill, dark text); hairlines and nested radii; row actions on hover or
 * keyboard focus only; color only for real state (warning, stop).
 */
export const AI_USAGE_CSS = `
.aiu { --aiu-r: 14px; --aiu-warn: #b7791f; --aiu-stop: var(--bad); max-width: 760px; }
@media (prefers-color-scheme: dark) { .aiu { --aiu-warn: #e5c07b; } }
.aiu-title { font-size: 26px; line-height: 1.2; font-weight: 650; letter-spacing: -0.01em; margin: 28px 0 6px; }
.aiu-intro { color: var(--muted); margin: 0 0 18px; max-width: 60ch; }
.aiu-surface { background: var(--card); border: 1px solid var(--line); border-radius: var(--aiu-r); padding: 16px 18px; margin: 0 0 14px; }
.aiu-list { padding: 4px 6px; }
.aiu-line { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; margin-bottom: 10px; }
.aiu-figure { font-size: 20px; font-weight: 600; font-variant-numeric: tabular-nums; }
.aiu-meta { color: var(--muted); font-size: 13px; }
.aiu-muted { color: var(--muted); }
.aiu-status { margin: 10px 0 0; font-size: 13px; }
.aiu-warn { color: var(--aiu-warn); } .aiu-bad { color: var(--aiu-stop); }
.aiu-bar { height: 4px; border-radius: 2px; background: color-mix(in srgb, var(--fg) 10%, transparent); overflow: hidden; }
.aiu-bar-fill { height: 100%; border-radius: 2px; background: color-mix(in srgb, var(--fg) 55%, transparent); }
.aiu-bar-fill.aiu-near { background: var(--aiu-warn); } .aiu-bar-fill.aiu-stopped { background: var(--aiu-stop); }
.aiu-bar-fill.aiu-over, .aiu-bar-fill.aiu-over_free { background: var(--fg); }
.aiu-row { display: flex; align-items: center; gap: 16px; min-height: 44px; padding: 8px 12px; border-radius: calc(var(--aiu-r) - 6px); }
.aiu-row + .aiu-row { border-top: 1px solid var(--line); }
.aiu-row-hover:hover, .aiu-row-hover:focus-within, .aiu-row-hover:focus-visible { background: color-mix(in srgb, var(--fg) 4%, transparent); outline: none; }
.aiu-default .aiu-name { flex: 0 0 auto; } .aiu-default .aiu-meta { flex: 1; min-width: 0; }
.aiu-who { display: flex; flex-direction: column; min-width: 0; flex: 1; }
.aiu-name { font-weight: 550; overflow-wrap: anywhere; }
.aiu-spend { flex: 0 1 300px; min-width: 210px; display: flex; flex-direction: column; gap: 6px; }
.aiu-amounts { display: flex; align-items: baseline; gap: 8px; white-space: nowrap; font-variant-numeric: tabular-nums; }
.aiu-flag { font-size: 12px; white-space: nowrap; }
.aiu-actions { display: inline-flex; gap: 2px; margin-left: auto; visibility: hidden; }
.aiu-row-hover:hover .aiu-actions, .aiu-row-hover:focus-within .aiu-actions, .aiu-row-hover:focus-visible .aiu-actions { visibility: visible; }
.aiu button.aiu-text { border: 0; background: none; color: var(--muted); padding: 2px 6px; border-radius: 6px; font-size: 13px; }
.aiu button.aiu-text:hover, .aiu button.aiu-text:focus-visible { color: var(--fg); background: color-mix(in srgb, var(--fg) 7%, transparent); }
.aiu button.aiu-primary { background: var(--fg); color: var(--bg); border: 0; border-radius: 7px; padding: 4px 12px; }
.aiu button.aiu-primary:disabled { opacity: 0.4; cursor: default; }
.aiu-edit { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
.aiu-edit input { width: 7em; font-variant-numeric: tabular-nums; }
.aiu-dollar { color: var(--muted); }
.aiu-hint { flex-basis: 100%; color: var(--muted); font-size: 12px; }
`
