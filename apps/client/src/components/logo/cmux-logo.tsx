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
  /** Toggle the wordmark. Set false for arrow-only. */
  showWordmark?: boolean; // default true
  /** Debug: draw guides and border */
  showGuides?: boolean;
  showBorder?: boolean;
  /** Debug: position/scale overrides for the mark */
  markTranslateX?: number;
  markTranslateY?: number;
  markScale?: number;
};

export default function CmuxLogo({
  height = "1em",
  label,
  from = "#00D4FF",
  to = "#7C3AED",
  showWordmark = true,
  showGuides = false,
  showBorder = false,
  markTranslateX = 87.2,
  markTranslateY = 62.7,
  markScale = 0.2,
  style,
  ...rest
}: Props) {
  const id = React.useId();
  const gradId = `cmuxGradient-${id}`;
  const titleId = label ? `cmuxTitle-${id}` : undefined;

  const css = `
    .mark-line { stroke: url(#${gradId}); stroke-width: 14; stroke-linecap: round; }
    .mark-fill { fill: url(#${gradId}); }
    .wordmark  { font-weight: 700; letter-spacing: 1.5px;
                 font-family: "JetBrains Mono","SFMono-Regular","Menlo","Consolas","ui-monospace","Monaco","Courier New",monospace; }
  `;

  return (
    <svg
      viewBox="60 0 680 240"
      role="img"
      aria-labelledby={label ? titleId : undefined}
      aria-hidden={label ? undefined : true}
      preserveAspectRatio="xMinYMid meet"
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
        {/* Arrow filter and gradient */}
        <filter
          id="filter0_dd_116_97"
          x="0"
          y="0"
          width="517"
          height="667"
          filterUnits="userSpaceOnUse"
          colorInterpolationFilters="sRGB"
        >
          <feFlood floodOpacity="0" result="BackgroundImageFix" />
          <feColorMatrix
            in="SourceAlpha"
            type="matrix"
            values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0"
            result="hardAlpha"
          />
          <feOffset />
          <feGaussianBlur stdDeviation="32" />
          <feComposite in2="hardAlpha" operator="out" />
          <feColorMatrix
            type="matrix"
            values="0 0 0 0 0.14902 0 0 0 0 0.65098 0 0 0 0 0.980392 0 0 0 0.3 0"
          />
          <feBlend
            mode="normal"
            in2="BackgroundImageFix"
            result="effect1_dropShadow_116_97"
          />
          <feColorMatrix
            in="SourceAlpha"
            type="matrix"
            values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0"
            result="hardAlpha"
          />
          <feOffset dy="4" />
          <feGaussianBlur stdDeviation="8" />
          <feComposite in2="hardAlpha" operator="out" />
          <feColorMatrix
            type="matrix"
            values="0 0 0 0 0.14902 0 0 0 0 0.65098 0 0 0 0 0.980392 0 0 0 0.4 0"
          />
          <feBlend
            mode="normal"
            in2="effect1_dropShadow_116_97"
            result="effect2_dropShadow_116_97"
          />
          <feBlend
            mode="normal"
            in="SourceGraphic"
            in2="effect2_dropShadow_116_97"
            result="shape"
          />
        </filter>
        <linearGradient
          id="paint0_linear_116_97"
          x1="64"
          y1="64"
          x2="38964"
          y2="64"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#00D4FF" />
          <stop offset="0.0120866" stopColor="#7C3AED" />
          <stop offset="0.024529" stopColor="#7C3AED" />
        </linearGradient>
      </defs>

      {/* Logomark (left-flush) */}
      {/* Replaced arrow with new SVG path */}
      {/* Scale and position the new arrow to fit existing layout */}
      <g transform={`translate(${markTranslateX}, ${markTranslateY}) scale(${markScale})`}>
        <g filter="url(#filter0_dd_116_97)">
          <path
            d="M64 64L453 333.5L64 603V483.222L273.462 333.5L64 183.778V64Z"
            fill="url(#paint0_linear_116_97)"
          />
        </g>
      </g>

      {/* Wordmark */}
      {showWordmark && (
        <text
          className="wordmark fill-neutral-900 dark:fill-white"
          x={208}
          y={162}
          fontSize={108}
        >
          cmux
        </text>
      )}

      {/* Debug guides and border */}
      {showGuides ? (
        <g className="pointer-events-none">
          {/* SVG border */}
          {showBorder ? (
            <rect
              x={60}
              y={0}
              width={680}
              height={240}
              fill="none"
              className="stroke-neutral-300 dark:stroke-neutral-700"
              strokeWidth={1}
            />
          ) : null}
          {/* Center crosshair */}
          <line
            x1={400}
            y1={0}
            x2={400}
            y2={240}
            className="stroke-neutral-200 dark:stroke-neutral-800"
            strokeWidth={1}
            strokeDasharray="4 4"
          />
          <line
            x1={60}
            y1={120}
            x2={740}
            y2={120}
            className="stroke-neutral-200 dark:stroke-neutral-800"
            strokeWidth={1}
            strokeDasharray="4 4"
          />
          {/* Text baseline */}
          {showWordmark ? (
            <line
              x1={60}
              y1={162}
              x2={740}
              y2={162}
              className="stroke-neutral-400 dark:stroke-neutral-600"
              strokeWidth={1}
            />
          ) : null}
        </g>
      ) : null}
    </svg>
  );
}
