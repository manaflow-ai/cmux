import { agentBrand, agentBrandSpec, type BrandTone } from "../agentBrands.generated";
import type { Provider } from "../session";

const PROVIDER_COLOR: Record<string, string> = {
  claude: "#d97757",
  codex: "#10a37f",
  opencode: "#f2a600",
  pi: "#8b7cff",
  gemini: "#4285f4",
};

export function colorFor(id: string): string {
  if (PROVIDER_COLOR[id]) return PROVIDER_COLOR[id];
  let h = 0;
  for (const c of id) h = (h * 31 + c.charCodeAt(0)) % 360;
  return `hsl(${h} 60% 60%)`;
}

export function basename(p: string): string {
  const t = String(p || "").replace(/\/+$/, "");
  return t.split("/").pop() || t || "~";
}

function Dot({ id }: { id: string }) {
  return <span className="dot" style={{ background: colorFor(id), color: colorFor(id) }} />;
}

function themeIsDark(): boolean {
  const bg = getComputedStyle(document.documentElement).getPropertyValue("--bg").trim();
  const m = bg.match(/^#([0-9a-f]{6})$/i);
  if (!m) return true;
  const n = parseInt(m[1], 16);
  const r = (n >> 16) & 255;
  const g = (n >> 8) & 255;
  const b = n & 255;
  return (r * 299 + g * 587 + b * 114) / 1000 < 150;
}

const tone = (value: BrandTone, dark: boolean) => (typeof value === "string" ? value : dark ? value[0] : value[1]);

/// The provider's brand mark from design/agent-icons (agentBrands.generated.ts), in the
/// owner's colors for the theme; a provider without a mark draws a colored dot.
export function ProviderIcon({ provider }: { provider: Provider }) {
  const spec = agentBrandSpec(provider.id);
  if (!spec) return <Dot id={provider.id} />;
  const dark = themeIsDark();
  const box = spec.tile?.viewBox ?? spec.viewBox;
  return (
    <svg className="provider-icon" data-agent={agentBrand(provider.id)} viewBox={box.join(" ")} fill={tone(spec.tone, dark)} aria-hidden="true">
      {spec.tile && <rect x={box[0]} y={box[1]} width={box[2]} height={box[3]} rx={spec.tile.radius} fill={tone(spec.tile.tone, dark)} />}
      {spec.paths.map((path, index) =>
        path.strokeWidth ? (
          <path key={index} d={path.d} fill="none" stroke={path.tone ? tone(path.tone, dark) : tone(spec.tone, dark)} strokeWidth={path.strokeWidth} />
        ) : (
          <path key={index} d={path.d} fill={path.tone ? tone(path.tone, dark) : undefined} fillRule={path.evenOdd ? "evenodd" : undefined} />
        ),
      )}
    </svg>
  );
}

export const ArrowUp = () => (
  <svg viewBox="0 0 16 16" width="16" height="16"><path d="M8 13V3.5M4 7l4-4 4 4" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const Chevron = () => (
  <svg viewBox="0 0 10 6" width="10" height="6"><path d="M1 1l4 4 4-4" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const Check = () => (
  <svg viewBox="0 0 12 12" width="12" height="12"><path d="M2.5 6.2l2.3 2.3L9.5 3.5" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const FolderIcon = () => (
  <svg viewBox="0 0 14 12" width="13" height="11" fill="none" stroke="currentColor" strokeWidth="1.2"><path d="M1 3.4c0-.7.5-1.3 1.2-1.3h2.5l1.2 1.4h5.7c.7 0 1.2.6 1.2 1.3v4.9c0 .7-.5 1.3-1.2 1.3H2.2C1.5 11 1 10.4 1 9.7z" /></svg>
);
export const SparkIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8 2v12M2 8h12M3.8 3.8l8.4 8.4M12.2 3.8l-8.4 8.4" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" /></svg>
);
export const BoltIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8.8 1.8L3.9 8.7h3.6l-.5 5.5 5.1-7.1H8.4l.4-5.3z" fill="currentColor" /></svg>
);
export function BarsIcon({ filled = 4, bars = 4 }: { filled?: number; bars?: number }) {
  const count = Math.max(1, bars);
  const active = Math.max(0, Math.min(count, filled));
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">
      {Array.from({ length: count }, (_, i) => {
        const x = 3 + (i * 10) / Math.max(1, count - 1);
        const h = 2.2 + (i * 8.2) / Math.max(1, count - 1);
        return (
          <path
            key={i}
            d={`M${x.toFixed(1)} 12V${(12 - h).toFixed(1)}`}
            fill="none"
            stroke="currentColor"
            strokeWidth="1.7"
            strokeLinecap="round"
            opacity={i < active ? 1 : 0.35}
          />
        );
      })}
    </svg>
  );
}
export const PlanIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M2.5 4.3l3.4-1.5 4.2 1.5 3.4-1.5v8.9l-3.4 1.5-4.2-1.5-3.4 1.5V4.3zM5.9 2.8v8.9M10.1 4.3v8.9" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const ShieldIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8 2.2l4.7 1.7v3.6c0 3.1-1.9 5.3-4.7 6.3-2.8-1-4.7-3.2-4.7-6.3V3.9L8 2.2z" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round" /><path d="M5.8 7.9l1.4 1.4 3-3.1" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const EllipsisIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M3.5 8h.1M8 8h.1M12.5 8h.1" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" /></svg>
);
export const SearchIcon = () => (
  <svg viewBox="0 0 16 16" width="14" height="14"><path d="M7 12.2a5.2 5.2 0 1 1 0-10.4 5.2 5.2 0 0 1 0 10.4zM11 11l3 3" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" /></svg>
);
export const CopyIcon = () => (
  <svg viewBox="0 0 16 16" width="14" height="14"><path d="M5.2 5.2h7.1v7.1H5.2zM3.7 10.8H3V3.7h7.1v.7" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round" /></svg>
);

export function PinwheelSpinner({ size = 14 }: { size?: number }) {
  return (
    <svg className="pinwheel-spinner" viewBox="0 0 16 16" width={size} height={size} aria-hidden="true">
      {Array.from({ length: 8 }, (_, i) => (
        <line
          key={i}
          x1="8"
          y1="2.5"
          x2="8"
          y2="5"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          opacity={0.2 + i * 0.1}
          transform={`rotate(${i * 45} 8 8)`}
        />
      ))}
    </svg>
  );
}
