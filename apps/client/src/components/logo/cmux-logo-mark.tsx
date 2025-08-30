import * as React from "react";

type Props = Omit<
  React.SVGProps<SVGSVGElement>,
  "width" | "height" | "title"
> & {
  /** Visual height (e.g. "1.5rem", 48). Width stays proportional. Default: "1em". */
  height?: number | string;
  /** Accessible label (screen readers only). If omitted, the SVG is aria-hidden. */
  label?: string;
  /** Gradient colors for the mark. */
  from?: string; // default "#00D4FF"
  to?: string; // default "#7C3AED"
};

export default function CmuxLogoMark({
  height = "1em",
  label,
  from = "#00D4FF",
  to = "#7C3AED",
  style,
  ...rest
}: Props) {
  const id = React.useId();
  const gradId = `cmuxGradient-${id}`;
  const titleId = label ? `cmuxTitle-${id}` : undefined;

  const css = `
    .mark-fill { fill: url(#${gradId}); }
  `;

  return (
    <svg
      viewBox="0 0 64 64"
      role="img"
      aria-labelledby={label ? titleId : undefined}
      aria-hidden={label ? undefined : true}
      preserveAspectRatio="xMidYMid meet"
      style={{
        display: "inline-block",
        verticalAlign: "middle",
        height,
        width: "auto",
        ...style,
      }}
      {...rest}
    >
      {label ? <title id={titleId}>{label}</title> : null}

      <defs>
        <linearGradient id={gradId} x1="0%" y1="0%" x2="100%" y2="0%">
          <stop offset="0%" stopColor={from} />
          <stop offset="100%" stopColor={to} />
        </linearGradient>
        <style>{css}</style>
      </defs>

      {/* Logomark - optimized coordinates for tight viewBox */}
      <polygon className="mark-fill" points="8,16 56,32 8,48 8,40 40,32 8,24" />
    </svg>
  );
}
