"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useId,
  Suspense,
} from "react";
import {
  Camera,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  ExternalLink,
  FileText,
  Folder,
  GitBranch,
  GitCompare as GitCompareIcon,
  Github,
  Home,
  // Link2, // commented out: quick setup input is disabled
  Loader2,
  Monitor,
  MoreVertical,
  Pencil,
  Plus,
  Search,
  Server,
  Settings,
  Star,
  TerminalSquare,
  Trash2,
  X,
} from "lucide-react";
import Image from "next/image";
import Link from "next/link";
import clsx from "clsx";
import {
  QueryClient,
  QueryClientProvider,
  useQuery,
} from "@tanstack/react-query";
import { useUser } from "@stackframe/stack";
import { Button } from "@/components/ui/button";
import CmuxLogo from "@/components/logo/cmux-logo";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip-base";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { LucideIcon } from "lucide-react";
import { useOAuthPopup } from "@/hooks/use-oauth-popup";
import { PreviewItemButton } from "./preview-item-button";
import { BlinkingCursor } from "./blinking-cursor";
import { UseDifferentAccountButton } from "./use-different-account-button";

type ProviderConnection = {
  id: string;
  installationId: number;
  accountLogin: string | null;
  accountType: string | null;
  isActive: boolean;
};

type RepoSearchResult = {
  name: string;
  full_name: string;
  private: boolean;
  updated_at?: string | null;
  pushed_at?: string | null;
};

type PreviewConfigStatus = "active" | "paused" | "disabled";

type PreviewConfigListItem = {
  id: string;
  repoFullName: string;
  environmentId: string | null;
  repoInstallationId: number | null;
  repoDefaultBranch: string | null;
  status: PreviewConfigStatus;
  lastRunAt: number | null;
  teamSlugOrId: string;
  teamName: string;
};

type TeamOption = {
  slugOrId: string;
  displayName: string;
};

type PreviewPaywallState = {
  isBlocked: boolean;
  hasPaid: boolean;
  usedRuns: number;
  freeLimit: number;
  productId: string;
};

type PreviewDashboardProps = {
  selectedTeamSlugOrId: string;
  teamOptions: TeamOption[];
  providerConnectionsByTeam: Record<string, ProviderConnection[]>;
  isAuthenticated: boolean;
  previewConfigs: PreviewConfigListItem[];
  popupComplete?: boolean;
  /** When set, user authenticated with these providers but GitHub is not connected yet - show waitlist */
  waitlistProviders?: ("gitlab" | "bitbucket")[];
  /** Email to display on waitlist screen */
  waitlistEmail?: string | null;
  paywall?: PreviewPaywallState | null;
};

const ADD_INSTALLATION_VALUE = "__add_github_account__";

function VSCodeIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 100 100" fill="none">
      <mask
        id="mask0"
        // @ts-expect-error maskType is valid SVG attribute
        maskType="alpha"
        maskUnits="userSpaceOnUse"
        x="0"
        y="0"
        width="100"
        height="100"
      >
        <path
          fillRule="evenodd"
          clipRule="evenodd"
          d="M70.9119 99.3171C72.4869 99.9307 74.2828 99.8914 75.8725 99.1264L96.4608 89.2197C98.6242 88.1787 100 85.9892 100 83.5872V16.4133C100 14.0113 98.6243 11.8218 96.4609 10.7808L75.8725 0.873756C73.7862 -0.130129 71.3446 0.11576 69.5135 1.44695C69.252 1.63711 69.0028 1.84943 68.769 2.08341L29.3551 38.0415L12.1872 25.0096C10.589 23.7965 8.35363 23.8959 6.86933 25.2461L1.36303 30.2549C-0.452552 31.9064 -0.454633 34.7627 1.35853 36.417L16.2471 50.0001L1.35853 63.5832C-0.454633 65.2374 -0.452552 68.0938 1.36303 69.7453L6.86933 74.7541C8.35363 76.1043 10.589 76.2037 12.1872 74.9905L29.3551 61.9587L68.769 97.9167C69.3925 98.5406 70.1246 99.0104 70.9119 99.3171ZM75.0152 27.2989L45.1091 50.0001L75.0152 72.7012V27.2989Z"
          fill="currentColor"
        />
      </mask>
      <g mask="url(#mask0)">
        <path
          d="M96.4614 10.7962L75.8569 0.875542C73.4719 -0.272773 70.6217 0.211611 68.75 2.08333L1.29858 63.5832C-0.515693 65.2373 -0.513607 68.0937 1.30308 69.7452L6.81272 74.754C8.29793 76.1042 10.5347 76.2036 12.1338 74.9905L93.3609 13.3699C96.086 11.3026 100 13.2462 100 16.6667V16.4433C100 14.0412 98.6246 11.8214 96.4614 10.7962Z"
          fill="#0065A9"
        />
        <g filter="url(#filter0_d)">
          <path
            d="M96.4614 89.2038L75.8569 99.1245C73.4719 100.273 70.6217 99.7884 68.75 97.9167L1.29858 36.4169C-0.515693 34.7627 -0.513607 31.9063 1.30308 30.2548L6.81272 25.246C8.29793 23.8958 10.5347 23.7964 12.1338 25.0095L93.3609 86.6301C96.086 88.6974 100 86.7538 100 83.3334V83.5567C100 85.9588 98.6246 88.1786 96.4614 89.2038Z"
            fill="#007ACC"
          />
        </g>
        <g filter="url(#filter1_d)">
          <path
            d="M75.8578 99.1263C73.4721 100.274 70.6219 99.7885 68.75 97.9166C71.0564 100.223 75 98.5895 75 95.3278V4.67213C75 1.41039 71.0564 -0.223106 68.75 2.08329C70.6219 0.211402 73.4721 -0.273666 75.8578 0.873633L96.4587 10.7807C98.6234 11.8217 100 14.0112 100 16.4132V83.5871C100 85.9891 98.6234 88.1786 96.4586 89.2196L75.8578 99.1263Z"
            fill="#1F9CF0"
          />
        </g>
        <g style={{ mixBlendMode: "overlay" }} opacity="0.25">
          <path
            fillRule="evenodd"
            clipRule="evenodd"
            d="M70.8511 99.3171C72.4261 99.9306 74.2221 99.8913 75.8117 99.1264L96.4 89.2197C98.5634 88.1787 99.9392 85.9892 99.9392 83.5871V16.4133C99.9392 14.0112 98.5635 11.8217 96.4001 10.7807L75.8117 0.873695C73.7255 -0.13019 71.2838 0.115699 69.4527 1.44688C69.1912 1.63705 68.942 1.84937 68.7082 2.08335L29.2943 38.0414L12.1264 25.0096C10.5283 23.7964 8.29285 23.8959 6.80855 25.246L1.30225 30.2548C-0.513334 31.9064 -0.515415 34.7627 1.29775 36.4169L16.1863 50L1.29775 63.5832C-0.515415 65.2374 -0.513334 68.0937 1.30225 69.7452L6.80855 74.754C8.29285 76.1042 10.5283 76.2036 12.1264 74.9905L29.2943 61.9586L68.7082 97.9167C69.3317 98.5405 70.0638 99.0104 70.8511 99.3171ZM74.9544 27.2989L45.0483 50L74.9544 72.7012V27.2989Z"
            fill="url(#paint0_linear)"
          />
        </g>
      </g>
      <defs>
        <filter
          id="filter0_d"
          x="-8.39411"
          y="15.8291"
          width="116.727"
          height="92.2456"
          filterUnits="userSpaceOnUse"
          colorInterpolationFilters="sRGB"
        >
          <feFlood floodOpacity="0" result="BackgroundImageFix" />
          <feColorMatrix
            in="SourceAlpha"
            type="matrix"
            values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0"
          />
          <feOffset />
          <feGaussianBlur stdDeviation="4.16667" />
          <feColorMatrix
            type="matrix"
            values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.25 0"
          />
          <feBlend
            mode="normal"
            in2="BackgroundImageFix"
            result="effect1_dropShadow"
          />
          <feBlend
            mode="normal"
            in="SourceGraphic"
            in2="effect1_dropShadow"
            result="shape"
          />
        </filter>
        <filter
          id="filter1_d"
          x="66.6666"
          y="-8.33333"
          width="41.6667"
          height="116.667"
          filterUnits="userSpaceOnUse"
          colorInterpolationFilters="sRGB"
        >
          <feFlood floodOpacity="0" result="BackgroundImageFix" />
          <feColorMatrix
            in="SourceAlpha"
            type="matrix"
            values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.25 0"
          />
          <feBlend
            mode="normal"
            in2="BackgroundImageFix"
            result="effect1_dropShadow"
          />
          <feBlend
            mode="normal"
            in="SourceGraphic"
            in2="effect1_dropShadow"
            result="shape"
          />
        </filter>
        <linearGradient
          id="paint0_linear"
          x1="6.82062"
          y1="0.874534"
          x2="45.5753"
          y2="38.2241"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="white" />
          <stop offset="1" stopColor="white" stopOpacity="0" />
        </linearGradient>
      </defs>
    </svg>
  );
}

type FeatureCardProps = {
  icon: LucideIcon;
  iconBgColor: string;
  iconColor: string;
  title: string;
  description: string;
};

function GrainOverlay({ opacity = 0.08 }: { opacity?: number }) {
  return (
    <div
      className="pointer-events-none absolute inset-0 mix-blend-overlay"
      style={{
        opacity,
        backgroundImage: `url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)'/%3E%3C/svg%3E")`,
      }}
    />
  );
}

function CmuxMarkIcon({
  size = 16,
  className,
  color,
}: {
  size?: number;
  className?: string;
  /** Solid color override. When set, disables gradient and uses this color. Use "currentColor" to inherit from parent. */
  color?: string;
}) {
  const id = useId();
  const gradId = `cmuxMarkGradient-${id}`;
  const glowId = `cmuxMarkGlow-${id}`;
  const fillValue = color ?? `url(#${gradId})`;

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 517 667"
      className={className}
      role="img"
      aria-hidden
    >
      <defs>
        <linearGradient id={gradId} x1="0%" y1="0%" x2="100%" y2="0%">
          <stop offset="0%" stopColor="#00D4FF" />
          <stop offset="100%" stopColor="#7C3AED" />
        </linearGradient>
        <filter
          id={glowId}
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
            result="effect1_dropShadow"
          />
          <feColorMatrix
            in="SourceAlpha"
            type="matrix"
            values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0"
            result="hardAlpha2"
          />
          <feOffset dy="4" />
          <feGaussianBlur stdDeviation="8" />
          <feComposite in2="hardAlpha2" operator="out" />
          <feColorMatrix
            type="matrix"
            values="0 0 0 0 0.14902 0 0 0 0 0.65098 0 0 0 0 0.980392 0 0 0 0.4 0"
          />
          <feBlend
            mode="normal"
            in2="effect1_dropShadow"
            result="effect2_dropShadow"
          />
          <feBlend
            mode="normal"
            in="SourceGraphic"
            in2="effect2_dropShadow"
            result="shape"
          />
        </filter>
      </defs>

      <g filter={`url(#${glowId})`}>
        <path
          d="M64 64L453 333.5L64 603V483.222L273.462 333.5L64 183.778V64Z"
          fill={fillValue}
        />
      </g>
    </svg>
  );
}

function FeatureCard({
  icon: _Icon,
  iconBgColor: _iconBgColor,
  iconColor: _iconColor,
  title,
  description,
}: FeatureCardProps) {
  return (
    <div className="relative flex items-start rounded-lg border border-white/5 bg-white/[0.01] backdrop-blur-sm p-4 overflow-hidden">
      <GrainOverlay />
      <div className="relative">
        <h4 className="text-sm font-medium text-white pb-1">{title}</h4>
        <p className="text-[13px] text-neutral-300/90 leading-tight">
          {description}
        </p>
      </div>
    </div>
  );
}

type SectionProps = {
  title: string;
  headerContent?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
  inlineHeader?: boolean;
};

function TabFavicon({ className }: { className?: string }) {
  return (
    <span
      className={clsx(
        "flex items-center justify-center leading-none shrink-0",
        className
      )}
    >
      <CmuxMarkIcon size={16} />
    </span>
  );
}

type ChromeTabProps = {
  icon: React.ReactNode;
  label: string;
  isActive: boolean;
  onClick: () => void;
  onClose?: () => void;
};

function ChromeTab({
  icon,
  label,
  isActive,
  onClick,
  onClose,
}: ChromeTabProps) {
  return (
    <button
      onMouseDown={onClick}
      onClick={onClick}
      className={clsx(
        "group relative flex items-center gap-2 pl-3 pr-2 pb-0.5 text-xs font-medium w-[240px] h-[33px]",
        isActive ? "bg-[#35363A] text-[#E8EAED] rounded-t-lg" : "text-[#9AA0A6]"
      )}
    >
      {/* Active tab curved corners connectors */}
      {isActive && (
        <>
          <div className="absolute bottom-0 -left-3 size-3 pointer-events-none shadow-[3px_3px_0_0_#35363A] rounded-br-full" />
          <div className="absolute bottom-0 -right-3 size-3 pointer-events-none shadow-[-3px_3px_0_0_#35363A] rounded-bl-full" />
        </>
      )}
      {/* Hover pill for inactive tab */}
      {!isActive && (
        <div className="absolute inset-x-0 top-0 bottom-[3px] rounded-[9px] bg-transparent group-hover:bg-[#35363A]/70 transition-colors" />
      )}

      <span className="shrink-0 relative z-10">{icon}</span>
      <span className="truncate flex-1 text-left relative z-10">{label}</span>
      <span
        className="p-0.5 rounded-full hover:bg-white/20 transition-all relative z-10 active:bg-white/20"
        onClick={(e) => {
          e.stopPropagation();
          onClose?.();
        }}
      >
        <svg
          className="h-3 w-3 shrink-0"
          viewBox="0 0 16 16"
          fill="currentColor"
        >
          <path d="M3.72 3.72a.75.75 0 0 1 1.06 0L8 6.94l3.22-3.22a.749.749 0 0 1 1.275.326.749.749 0 0 1-.215.734L9.06 8l3.22 3.22a.749.749 0 0 1-.326 1.275.749.749 0 0 1-.734-.215L8 9.06l-3.22 3.22a.751.751 0 0 1-1.042-.018.751.751 0 0 1-.018-1.042L6.94 8 3.72 4.78a.75.75 0 0 1 0-1.06Z" />
        </svg>
      </span>
    </button>
  );
}

// VS Code style tab component (used for LAUNCH.md and browser tabs)
type VSCodeTabProps = {
  icon: React.ReactNode;
  label: string;
  isActive?: boolean;
  onClose?: () => void;
};

function VSCodeTab({ icon, label, isActive = true, onClose }: VSCodeTabProps) {
  return (
    <div
      className={clsx(
        "flex items-center gap-1 px-3 py-1 text-[11px]",
        isActive
          ? "bg-[#1e1e1e] border-r border-[#2d2d2d] text-[#cccccc]"
          : "bg-[#2d2d2d] text-[#969696]"
      )}
    >
      {icon}
      <span className="truncate">{label}</span>
      <X
        className="h-3 w-3 ml-1 text-[#858585] hover:text-white cursor-pointer"
        onClick={onClose}
      />
    </div>
  );
}

type VSCodeTabBarProps = {
  children: React.ReactNode;
};

function VSCodeTabBar({ children }: VSCodeTabBarProps) {
  return (
    <div className="flex items-center bg-[#252526] border-b border-[#2d2d2d]">
      {children}
    </div>
  );
}

function Section({
  title,
  headerContent,
  children,
  className,
  inlineHeader,
}: SectionProps) {
  return (
    <div className={`flex flex-col h-full ${className ?? ""}`}>
      <div
        className={`flex flex-col sm:flex-row sm:items-center ${inlineHeader ? "gap-2" : "justify-between gap-2"} h-auto sm:h-[34px] shrink-0 ${inlineHeader ? "pb-2" : "pb-3"}`}
      >
        <h2 className="text-base font-medium text-white">{title}</h2>
        {headerContent}
      </div>
      <div className="flex flex-col flex-1 min-h-0">{children}</div>
    </div>
  );
}

type MockScreenshot = {
  id: string;
  caption: string;
  imageUrl: string;
};

const MOCK_SCREENSHOTS: MockScreenshot[] = [
  {
    id: "1",
    caption:
      "Full page view of the initial setup screen showing framework preset selector, maintenance/dev scripts, and environment variables sections all expanded",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/330d59e9-de98-463e-a6d4-a1d571497b4e",
  },
  {
    id: "2",
    caption: "Header section showing 'Configure workspace' title",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/8733e153-847b-4700-9c85-859a09bfcf76",
  },
  {
    id: "3",
    caption:
      "Framework preset selector showing 'Vite' selected with autofill hint",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/2c878414-07a2-46ad-816a-ba3eeb61d48a",
  },
  {
    id: "4",
    caption:
      "Maintenance and Dev Scripts section expanded showing script input fields",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/4c392058-9bd7-4be9-8cfc-46cdf18633af",
  },
  {
    id: "5",
    caption:
      "Environment Variables section expanded with name/value input fields and reveal/hide toggle",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/017f34cf-6f10-46a0-af77-06d9fef44a84",
  },
  {
    id: "6",
    caption:
      "Full page view of workspace configuration showing sidebar with step-by-step wizard (step 3 active) and VS Code iframe embedded on the right",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/e6517fb1-194c-4128-9dc8-b0a7ed1ca67d",
  },
  {
    id: "7",
    caption: "Back to project setup button in the sidebar",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/767aa6b4-b584-4f44-9bb8-508f4edb8439",
  },
  {
    id: "8",
    caption:
      "Sidebar header showing Configure workspace title and repository name",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/494c475c-6fae-424b-acd5-be81cceb56a1",
  },
  {
    id: "9",
    caption:
      "Step 1 (Maintenance and Dev Scripts) in collapsed state with checkmark badge",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/bccc7af4-180e-45bc-94bf-77a3def45816",
  },
  {
    id: "10",
    caption:
      "Step 2 (Environment Variables) in collapsed state with checkmark badge",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/90e57824-11b9-4d79-919b-a43dfcdf16c1",
  },
  {
    id: "11",
    caption:
      "Step 3 (Run scripts in VS Code terminal) expanded showing instructions and command block",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/9bc44cf5-bd16-4f37-9312-62963d10311d",
  },
  {
    id: "12",
    caption:
      "Command block in step 3 showing combined maintenance and dev scripts with copy button",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/9c88db8b-9dee-4f33-8fc1-e695d3f225f1",
  },
  {
    id: "13",
    caption:
      "Full page view of workspace configuration at step 4 showing sidebar and browser VNC iframe on the right",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/61dfb080-6b98-4c28-82eb-70d675daf1ef",
  },
  {
    id: "14",
    caption:
      "Step 4 (Configure browser) expanded showing browser setup instructions",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/191dc959-3d69-4c53-8350-e7a986631f2b",
  },
  {
    id: "15",
    caption: "Step 3 (Run scripts) in collapsed state after moving to step 4",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/f4efebf5-a4ce-4297-9193-7a5b86166ef6",
  },
  {
    id: "16",
    caption: "Save configuration button shown at the end of step 4",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/cdb540a9-5e16-4d3c-bd82-96b551fc7a78",
  },
  {
    id: "17",
    caption:
      "Step 1 scripts section re-expanded in sidebar showing compact form with script input fields",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/aa3f1ee7-6849-4fc0-be2e-76ecf56e2a96",
  },
  {
    id: "18",
    caption:
      "Step 2 environment variables section re-expanded in sidebar showing compact form with env var inputs",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/80c2281a-e9ba-4007-9f0f-f6d44469c786",
  },
  {
    id: "19",
    caption:
      "Full page view showing multiple steps expanded simultaneously in the sidebar demonstrating component reuse",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/6853f198-8c7e-4383-9f27-05856250d888",
  },
  {
    id: "20",
    caption:
      "Full page view after clicking back button, returning to the initial setup layout",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/a6c469ed-ad11-4329-8d4f-88976a037a54",
  },
  {
    id: "21",
    caption:
      "Framework preset dropdown menu open showing all available options (Other, Next.js, Vite, Remix, Nuxt, SvelteKit, Angular, Create React App, Vue)",
    imageUrl:
      "https://famous-camel-162.convex.cloud/api/storage/a6c04dc1-7867-46e6-b359-e401c4acb224",
  },
];

function MockGitHubPRBrowser() {
  const [expandedImage, setExpandedImage] = useState<string | null>(null);
  const [activeTab, setActiveTab] = useState<"github" | "workspace">("github");
  const [activePRTab, setActivePRTab] = useState<
    "conversation" | "commits" | "checks" | "files"
  >("conversation");

  // State for collapsed git diff files (empty = all expanded by default)
  const [collapsedFiles, setCollapsedFiles] = useState<Set<string>>(new Set());

  // State for resizable panels (percentages)
  const [leftPanelWidth, setLeftPanelWidth] = useState(55); // Workspace panel width %
  const [topPanelHeight, setTopPanelHeight] = useState(50); // Browser panel height %

  // State for view mode: "all" shows three-panel layout, others show single panel
  type ViewMode = "all" | "workspace" | "browser" | "gitDiff" | "terminals";
  const [viewMode, setViewMode] = useState<ViewMode>("all");

  // State for expanded tasks in sidebar (Set allows multiple tasks to be expanded independently)
  const [expandedTasks, setExpandedTasks] = useState<Set<string>>(
    new Set(["task-1", "task-1-run"])
  );

  // State for which task is currently selected/active
  const [selectedTaskId, setSelectedTaskId] = useState<string>("task-1");

  // State for active tmux session
  const [activeTmuxSession, setActiveTmuxSession] = useState<number>(0);

  // State for reactions
  const [thumbsUpActive, setThumbsUpActive] = useState(false);
  const [rocketActive, setRocketActive] = useState(false);

  // State for PR merged status
  const [isPRMerged, setIsPRMerged] = useState(false);

  // Toggle expand/collapse for a task (only collapses, doesn't select)
  const toggleTaskExpanded = useCallback((taskId: string) => {
    setExpandedTasks((prev) => {
      const next = new Set(prev);
      if (next.has(taskId)) {
        next.delete(taskId);
      } else {
        next.add(taskId);
      }
      return next;
    });
  }, []);

  // Select a task: expands it and its run, sets it as selected, and shows 3-panel view
  const selectTask = useCallback((taskId: string) => {
    const runId = `${taskId}-run`;
    setExpandedTasks((prev) => {
      const next = new Set(prev);
      next.add(taskId); // Expand the task
      next.add(runId); // Also expand the screenshot-collector/run
      return next;
    });
    setSelectedTaskId(taskId);
    setViewMode("all");
  }, []);

  // Refs for resize handling
  const containerRef = useRef<HTMLDivElement>(null);
  const isResizingHorizontal = useRef(false);
  const isResizingVertical = useRef(false);
  const [isResizing, setIsResizing] = useState(false);

  const toggleFileCollapse = useCallback((fileId: string) => {
    setCollapsedFiles((prev) => {
      const next = new Set(prev);
      if (next.has(fileId)) {
        next.delete(fileId);
      } else {
        next.add(fileId);
      }
      return next;
    });
  }, []);

  const handleHorizontalResize = useCallback((e: MouseEvent) => {
    if (!isResizingHorizontal.current || !containerRef.current) return;
    const rect = containerRef.current.getBoundingClientRect();
    // Account for sidebar width (280px)
    const sidebarWidth = 280;
    const availableWidth = rect.width - sidebarWidth;
    const relativeX = e.clientX - rect.left - sidebarWidth;
    const newWidth = Math.min(
      Math.max((relativeX / availableWidth) * 100, 30),
      70
    );
    setLeftPanelWidth(newWidth);
  }, []);

  const handleVerticalResize = useCallback((e: MouseEvent) => {
    if (!isResizingVertical.current || !containerRef.current) return;
    const rect = containerRef.current.getBoundingClientRect();
    const relativeY = e.clientY - rect.top;
    const newHeight = Math.min(
      Math.max((relativeY / rect.height) * 100, 25),
      75
    );
    setTopPanelHeight(newHeight);
  }, []);

  const stopResizing = useCallback(() => {
    isResizingHorizontal.current = false;
    isResizingVertical.current = false;
    setIsResizing(false);
    document.body.style.cursor = "";
    document.body.classList.remove("select-none");
  }, []);

  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      if (isResizingHorizontal.current) {
        handleHorizontalResize(e);
      } else if (isResizingVertical.current) {
        handleVerticalResize(e);
      }
    };

    const handleMouseUp = () => {
      stopResizing();
    };

    window.addEventListener("mousemove", handleMouseMove);
    window.addEventListener("mouseup", handleMouseUp);

    return () => {
      window.removeEventListener("mousemove", handleMouseMove);
      window.removeEventListener("mouseup", handleMouseUp);
    };
  }, [handleHorizontalResize, handleVerticalResize, stopResizing]);

  const startHorizontalResize = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    isResizingHorizontal.current = true;
    setIsResizing(true);
    document.body.style.cursor = "col-resize";
    document.body.classList.add("select-none");
  }, []);

  const startVerticalResize = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    isResizingVertical.current = true;
    setIsResizing(true);
    document.body.style.cursor = "row-resize";
    document.body.classList.add("select-none");
  }, []);

  return (
    <div className="pt-12 pb-4 h-dvh w-screen relative left-1/2 -translate-x-1/2 px-4 flex flex-col">
      {/* Browser window frame - Chrome Dark Mode style */}
      <div className="rounded-2xl border border-[#35363A] bg-[#202124] overflow-hidden shadow-2xl w-full flex-1 flex flex-col min-h-0 max-w-[500px] sm:max-w-[600px] md:max-w-[700px] lg:max-w-[900px] xl:max-w-[1100px] 2xl:max-w-[1300px] mx-auto">
        {/* Tab strip */}
        <div className="flex items-end h-[38px] bg-[#202124] px-2 select-none">
          {/* Traffic lights */}
          <div className="flex items-center gap-2 px-2 pb-3">
            <div className="w-3 h-3 rounded-full bg-[#ff5f57] border border-[#e0443e]" />
            <div className="w-3 h-3 rounded-full bg-[#febc2e] border border-[#d89e24]" />
            <div className="w-3 h-3 rounded-full bg-[#28c840] border border-[#1aab29]" />
          </div>

          {/* Chrome-style tabs */}
          <div className="flex items-end ml-2 flex-1 min-w-0 pr-8 gap-[3px]">
            <ChromeTab
              icon={
                <svg
                  className="h-3.5 w-3.5"
                  viewBox="0 0 16 16"
                  fill="currentColor"
                >
                  <path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z" />
                </svg>
              }
              label="GitHub"
              isActive={activeTab === "github"}
              onClick={() => setActiveTab("github")}
            />
            <ChromeTab
              icon={<TabFavicon />}
              label="cmux"
              isActive={activeTab === "workspace"}
              onClick={() => setActiveTab("workspace")}
            />
          </div>
        </div>

        {/* URL bar toolbar */}
        <div className="flex items-center h-11 pl-[5px] pr-0 bg-[#35363A] border-b border-[#202124]">
          <div className="flex items-center gap-1 pr-2">
            <button className="p-2 text-[#E8EAED] opacity-60 hover:opacity-100 hover:bg-[#4A4B50] rounded-full transition-all">
              <svg className="h-4 w-4" viewBox="0 0 24 24" fill="currentColor">
                <path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z" />
              </svg>
            </button>
            <button className="p-2 text-[#E8EAED] opacity-60 hover:opacity-100 hover:bg-[#4A4B50] rounded-full transition-all">
              <svg className="h-4 w-4" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 4l-1.41 1.41L16.17 11H4v2h12.17l-5.58 5.59L12 20l8-8z" />
              </svg>
            </button>
            <button className="p-2 text-[#E8EAED] opacity-100 hover:bg-[#4A4B50] rounded-full transition-all">
              <svg className="h-4 w-4" viewBox="0 0 24 24" fill="currentColor">
                <path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z" />
              </svg>
            </button>
          </div>

          <div className="flex-1 flex items-center gap-3 px-3.5 py-1.5 bg-[#202124] rounded-full text-sm border border-transparent hover:border-[#5f6368] transition-colors cursor-text group">
            <svg
              className="h-3.5 w-3.5 text-[#9AA0A6] shrink-0"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
            >
              <rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
              <path d="M7 11V7a5 5 0 0 1 10 0v4" />
            </svg>
            <span className="text-[#E8EAED] truncate selection:bg-[#8ab4f8] selection:text-[#202124]">
              {activeTab === "github" ? (
                <>
                  <span className="text-[#9AA0A6]">github.com/</span>
                  <span>manaflow-ai/cmux/pull/1124</span>
                </>
              ) : (
                <>
                  <span className="text-[#9AA0A6]">https://</span>
                  <span>cmux.sh</span>
                </>
              )}
            </span>
          </div>

          <div className="flex items-center gap-1 px-1">
            <button className="p-2 text-[#E8EAED] opacity-60 hover:opacity-100 hover:bg-[#4A4B50] rounded-full transition-all">
              <MoreVertical className="h-4 w-4" />
            </button>
          </div>
        </div>

        {/* Content area - conditionally render based on active tab */}
        {activeTab === "github" ? (
          <div className="bg-[#0d1117] flex flex-col flex-1 min-h-0">
            {/* GitHub header */}
            <div className="bg-[#010409] border-b border-[#30363d] px-4 py-3 shrink-0">
              <div className="flex items-center gap-2 text-sm">
                <svg
                  className="h-4 w-4 text-[#7d8590]"
                  viewBox="0 0 16 16"
                  fill="currentColor"
                >
                  <path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z" />
                </svg>
                <a
                  href="https://www.ycombinator.com/companies/manaflow"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-[#e6edf3] font-semibold hover:underline cursor-pointer"
                >
                  manaflow-ai
                </a>
                <span className="text-[#7d8590]">/</span>
                <a
                  href="https://github.com/manaflow-ai/cmux"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-[#2f81f7] font-semibold hover:underline cursor-pointer"
                >
                  cmux
                </a>
              </div>
            </div>

            {/* PR header */}
            <div className="bg-[#0d1117] border-b border-[#30363d] px-6 py-4 shrink-0">
              <div className="flex items-start gap-2">
                <h1 className="text-xl font-semibold text-[#e6edf3]">
                  reuse preview config component for step by step re 6k4tq
                  <span className="text-[#7d8590] font-normal ml-2">#1124</span>
                </h1>
              </div>
              <div className="flex items-center gap-2 mt-2">
                <span
                  className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${isPRMerged ? "bg-[#8957e5]" : "bg-[#238636]"} text-white`}
                >
                  <svg
                    className="h-3 w-3"
                    viewBox="0 0 16 16"
                    fill="currentColor"
                  >
                    {isPRMerged ? (
                      <path d="M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z" />
                    ) : (
                      <path d="M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z" />
                    )}
                  </svg>
                  {isPRMerged ? "Merged" : "Open"}
                </span>
                <span className="text-sm text-[#7d8590]">
                  <a
                    href="https://x.com/austinywang"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="text-[#e6edf3] font-medium hover:text-[#2f81f7] cursor-pointer"
                  >
                    austinywang
                  </a>
                  {isPRMerged
                    ? " merged 14 commits into "
                    : " wants to merge 14 commits into "}
                  <span className="px-1.5 py-0.5 rounded-md bg-[#388bfd26] text-[#2f81f7] text-xs font-mono">
                    main
                  </span>
                  {" from "}
                  <span className="px-1.5 py-0.5 rounded-md bg-[#388bfd26] text-[#2f81f7] text-xs font-mono">cmux/test-re6k4tq</span>
                </span>
              </div>
            </div>

            {/* PR tabs */}
            <div className="bg-[#0d1117] border-b border-[#30363d] px-6 shrink-0">
              <nav className="flex gap-4">
                <button
                  onClick={() => setActivePRTab("conversation")}
                  className={clsx(
                    "flex items-center gap-2 px-2 py-3 text-sm -mb-px border-b-2 transition-colors",
                    activePRTab === "conversation"
                      ? "text-[#e6edf3] border-[#f78166]"
                      : "text-[#7d8590] hover:text-[#e6edf3] border-transparent"
                  )}
                >
                  <svg
                    className="h-4 w-4"
                    viewBox="0 0 16 16"
                    fill="currentColor"
                  >
                    <path d="M1.5 2.75a.25.25 0 0 1 .25-.25h8.5a.25.25 0 0 1 .25.25v5.5a.25.25 0 0 1-.25.25h-3.5a.75.75 0 0 0-.53.22L3.5 11.44V9.25a.75.75 0 0 0-.75-.75h-1a.25.25 0 0 1-.25-.25Zm-1.5 0a1.75 1.75 0 0 1 1.75-1.75h8.5A1.75 1.75 0 0 1 12 2.75v5.5A1.75 1.75 0 0 1 10.25 10H7.061l-2.574 2.573A1.458 1.458 0 0 1 2 11.543V10h-.25A1.75 1.75 0 0 1 0 8.25Zm14.5 2a.25.25 0 0 0-.25-.25h-.5a.75.75 0 0 1 0-1.5h.5A1.75 1.75 0 0 1 16 4.75v5.5A1.75 1.75 0 0 1 14.25 12H14v1.543a1.458 1.458 0 0 1-2.487 1.03L9.22 12.28a.749.749 0 0 1 .326-1.275.749.749 0 0 1 .734.215l2.22 2.22v-2.19a.75.75 0 0 1 .75-.75h1a.25.25 0 0 0 .25-.25Z" />
                  </svg>
                  <span className="relative">
                    <span
                      className={clsx(
                        "transition-opacity duration-150",
                        activePRTab === "conversation"
                          ? "opacity-0"
                          : "opacity-100"
                      )}
                    >
                      Conversation
                    </span>
                    <span
                      className={clsx(
                        "absolute inset-0 font-medium whitespace-nowrap transition-opacity duration-150",
                        activePRTab === "conversation"
                          ? "opacity-100"
                          : "opacity-0"
                      )}
                      aria-hidden="true"
                    >
                      Conversation
                    </span>
                  </span>
                  <span className="px-1.5 py-0.5 rounded-full bg-[#30363d] text-xs font-normal text-[#e6edf3]">
                    2
                  </span>
                </button>
                <button
                  onClick={() => setActivePRTab("commits")}
                  className={clsx(
                    "flex items-center gap-2 px-2 py-3 text-sm -mb-px border-b-2 transition-colors",
                    activePRTab === "commits"
                      ? "text-[#e6edf3] border-[#f78166]"
                      : "text-[#7d8590] hover:text-[#e6edf3] border-transparent"
                  )}
                >
                  <svg
                    className="h-4 w-4"
                    viewBox="0 0 16 16"
                    fill="currentColor"
                  >
                    <path d="M11.93 8.5a4.002 4.002 0 0 1-7.86 0H.75a.75.75 0 0 1 0-1.5h3.32a4.002 4.002 0 0 1 7.86 0h3.32a.75.75 0 0 1 0 1.5Zm-1.43-.75a2.5 2.5 0 1 0-5 0 2.5 2.5 0 0 0 5 0Z" />
                  </svg>
                  <span className="relative">
                    <span
                      className={clsx(
                        "transition-opacity duration-150",
                        activePRTab === "commits" ? "opacity-0" : "opacity-100"
                      )}
                    >
                      Commits
                    </span>
                    <span
                      className={clsx(
                        "absolute inset-0 font-medium whitespace-nowrap transition-opacity duration-150",
                        activePRTab === "commits" ? "opacity-100" : "opacity-0"
                      )}
                      aria-hidden="true"
                    >
                      Commits
                    </span>
                  </span>
                  <span className="px-1.5 py-0.5 rounded-full bg-[#30363d] text-xs font-normal text-[#e6edf3]">
                    14
                  </span>
                </button>
                <button
                  onClick={() => setActivePRTab("checks")}
                  className={clsx(
                    "flex items-center gap-2 px-2 py-3 text-sm -mb-px border-b-2 transition-colors",
                    activePRTab === "checks"
                      ? "text-[#e6edf3] border-[#f78166]"
                      : "text-[#7d8590] hover:text-[#e6edf3] border-transparent"
                  )}
                >
                  <svg
                    className="h-4 w-4"
                    viewBox="0 0 16 16"
                    fill="currentColor"
                  >
                    <path d="M1 7.775V2.75C1 1.784 1.784 1 2.75 1h5.025c.464 0 .91.184 1.238.513l6.25 6.25a1.75 1.75 0 0 1 0 2.474l-5.026 5.026a1.75 1.75 0 0 1-2.474 0l-6.25-6.25A1.752 1.752 0 0 1 1 7.775Zm1.5 0c0 .066.026.13.073.177l6.25 6.25a.25.25 0 0 0 .354 0l5.025-5.025a.25.25 0 0 0 0-.354l-6.25-6.25a.25.25 0 0 0-.177-.073H2.75a.25.25 0 0 0-.25.25ZM6 5a1 1 0 1 1 0 2 1 1 0 0 1 0-2Z" />
                  </svg>
                  <span className="relative">
                    <span
                      className={clsx(
                        "transition-opacity duration-150",
                        activePRTab === "checks" ? "opacity-0" : "opacity-100"
                      )}
                    >
                      Checks
                    </span>
                    <span
                      className={clsx(
                        "absolute inset-0 font-medium whitespace-nowrap transition-opacity duration-150",
                        activePRTab === "checks" ? "opacity-100" : "opacity-0"
                      )}
                      aria-hidden="true"
                    >
                      Checks
                    </span>
                  </span>
                  <span className="px-1.5 py-0.5 rounded-full bg-[#30363d] text-xs font-normal text-[#e6edf3]">
                    4
                  </span>
                </button>
                <button
                  onClick={() => setActivePRTab("files")}
                  className={clsx(
                    "flex items-center gap-2 px-2 py-3 text-sm -mb-px border-b-2 transition-colors",
                    activePRTab === "files"
                      ? "text-[#e6edf3] border-[#f78166]"
                      : "text-[#7d8590] hover:text-[#e6edf3] border-transparent"
                  )}
                >
                  <svg
                    className="h-4 w-4"
                    viewBox="0 0 16 16"
                    fill="currentColor"
                  >
                    <path d="M2 1.75C2 .784 2.784 0 3.75 0h6.586c.464 0 .909.184 1.237.513l2.914 2.914c.329.328.513.773.513 1.237v9.586A1.75 1.75 0 0 1 13.25 16h-9.5A1.75 1.75 0 0 1 2 14.25Zm1.75-.25a.25.25 0 0 0-.25.25v12.5c0 .138.112.25.25.25h9.5a.25.25 0 0 0 .25-.25V6h-2.75A1.75 1.75 0 0 1 9 4.25V1.5Zm6.75.062V4.25c0 .138.112.25.25.25h2.688l-.011-.013-2.914-2.914-.013-.011Z" />
                  </svg>
                  <span className="relative">
                    <span
                      className={clsx(
                        "transition-opacity duration-150",
                        activePRTab === "files" ? "opacity-0" : "opacity-100"
                      )}
                    >
                      Files changed
                    </span>
                    <span
                      className={clsx(
                        "absolute inset-0 font-medium whitespace-nowrap transition-opacity duration-150",
                        activePRTab === "files" ? "opacity-100" : "opacity-0"
                      )}
                      aria-hidden="true"
                    >
                      Files changed
                    </span>
                  </span>
                  <span className="px-1.5 py-0.5 rounded-full bg-[#30363d] text-xs font-normal text-[#e6edf3]">
                    2
                  </span>
                </button>
              </nav>
            </div>

            {/* GitHub PR content - scrollable */}
            <div
              className="bg-[#0d1117] overflow-y-auto flex-1 min-h-0"
              style={{
                scrollbarWidth: "thin",
                scrollbarColor: "#30363d #0d1117",
              }}
            >
              {activePRTab === "conversation" && (
                <div className="px-6 py-4 space-y-4">
                  {/* User's PR description comment */}
                  <div className="flex gap-3">
                    <div className="shrink-0 relative">
                      <Image
                        src="https://avatars.githubusercontent.com/u/38676809?v=4"
                        alt="austinywang"
                        width={40}
                        height={40}
                        className="rounded-full"
                        unoptimized
                      />
                      {/* Timeline connector line */}
                      <div className="absolute top-10 left-1/2 -translate-x-1/2 w-0.5 h-[calc(100%+16px)] bg-[#30363d]" />
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="rounded-md border border-[#30363d] overflow-hidden">
                        <div className="flex items-center gap-2 px-4 py-2 bg-[#161b22] border-b border-[#30363d]">
                          <a
                            href="https://x.com/austinywang"
                            target="_blank"
                            rel="noopener noreferrer"
                            className="font-semibold text-sm text-[#e6edf3] hover:text-[#2f81f7] cursor-pointer"
                          >
                            austinywang
                          </a>
                          <span className="text-sm text-[#7d8590]">
                            opened this pull request yesterday
                          </span>
                          <span className="ml-auto px-1.5 py-0.5 rounded-md text-xs font-medium bg-[#388bfd26] text-[#2f81f7] border border-[#388bfd66]">
                            Author
                          </span>
                        </div>
                        <div className="p-4 bg-[#0d1117]">
                          <h3 className="text-base font-semibold text-[#e6edf3] mb-2">
                            Summary
                          </h3>
                          <p className="text-sm text-[#e6edf3] mb-3">
                            This PR refactors the preview config component to be
                            reusable in the step-by-step wizard flow. The same
                            form components are now shared between the initial
                            setup page and the sidebar wizard. Feel free to
                            click around and explore. There may be some Easter
                            eggs &#123;-:
                          </p>
                          <h3 className="text-base font-semibold text-[#e6edf3] mb-2">
                            Changes
                          </h3>
                          <ul className="text-sm text-[#e6edf3] list-disc list-inside space-y-1">
                            <li>Extract shared form components</li>
                            <li>Add collapsible sections for wizard steps</li>
                            <li>Sync state between views</li>
                          </ul>
                        </div>
                      </div>
                    </div>
                  </div>

                  {/* Bot comment */}
                  <div className="flex gap-3">
                    <div className="shrink-0 w-10 h-10 rounded-full bg-[#0d1117] border border-[#30363d] flex items-center justify-center relative z-10">
                      <Image
                        src="https://avatars.githubusercontent.com/in/1690796?s=80&v=4"
                        alt="cmux-agent avatar"
                        width={40}
                        height={40}
                        className="rounded-full"
                        unoptimized
                      />
                    </div>

                    <div className="flex-1 min-w-0">
                      <div className="rounded-md border border-[#30363d] overflow-hidden">
                        <div className="flex items-center gap-2 px-4 py-2 bg-[#161b22] border-b border-[#30363d]">
                          <button
                            onClick={() => setActiveTab("workspace")}
                            className="font-semibold text-sm text-[#e6edf3] hover:text-[#2f81f7] cursor-pointer"
                          >
                            cmux-agent
                          </button>
                          <span className="px-1.5 py-0.5 rounded-md text-xs font-medium bg-[#6e40c926] text-[#a371f7] border border-[#6e40c966]">
                            bot
                          </span>
                          <span className="text-sm text-[#7d8590]">
                            commented yesterday
                          </span>
                        </div>

                        <div className="p-4 bg-[#0d1117]">
                          <h2 className="text-xl font-semibold text-[#e6edf3] pb-4 border-b border-[#30363d] mb-4">
                            Preview Screenshots
                          </h2>

                          <p className="text-sm text-[#e6edf3] mb-4">
                            <button
                              onClick={() => {
                                setActiveTab("workspace");
                                setViewMode("all");
                              }}
                              className="text-[#2f81f7] hover:underline cursor-pointer"
                            >
                              Open Workspace (1 hr expiry)
                            </button>
                            <span className="text-[#7d8590]"> · </span>
                            <button
                              onClick={() => {
                                setActiveTab("workspace");
                                setViewMode("browser");
                              }}
                              className="text-[#2f81f7] hover:underline cursor-pointer"
                            >
                              Open Dev Browser (1 hr expiry)
                            </button>
                            <span className="text-[#7d8590]"> · </span>
                            <a
                              href="https://0github.com/"
                              target="_blank"
                              rel="noopener noreferrer"
                              className="text-[#2f81f7] hover:underline cursor-pointer"
                            >
                              Open Diff Heatmap
                            </a>
                          </p>

                          <p className="text-sm text-[#e6edf3] mb-6">
                            Captured {MOCK_SCREENSHOTS.length} screenshots for
                            commit{" "}
                            <code className="px-1.5 py-0.5 rounded-md bg-[#6e768166] text-[#e6edf3] font-mono text-xs">
                              ee59b00
                            </code>{" "}
                            (2025-12-03 06:56:40.263 UTC).
                          </p>

                          <div className="space-y-6">
                            {MOCK_SCREENSHOTS.map((screenshot) => (
                              <div key={screenshot.id}>
                                <p className="text-sm text-[#e6edf3] mb-2">
                                  <strong>{screenshot.caption}</strong>
                                </p>
                                <button
                                  onClick={() =>
                                    setExpandedImage(
                                      expandedImage === screenshot.id
                                        ? null
                                        : screenshot.id
                                    )
                                  }
                                  className="block rounded-md border border-[#30363d] overflow-hidden hover:border-[#8b949e] transition-colors"
                                >
                                  <div
                                    className={clsx(
                                      "relative overflow-hidden transition-all duration-300",
                                      expandedImage === screenshot.id
                                        ? "max-h-[600px]"
                                        : "max-h-[300px]"
                                    )}
                                  >
                                    <Image
                                      src={screenshot.imageUrl}
                                      alt={screenshot.caption}
                                      width={800}
                                      height={450}
                                      unoptimized
                                      className="w-full h-auto"
                                    />
                                  </div>
                                </button>
                              </div>
                            ))}
                          </div>

                          <hr className="border-[#30363d] my-6" />

                          <p className="text-sm text-[#7d8590] italic">
                            Generated by{" "}
                            <button
                              onClick={() => {
                                setActiveTab("workspace");
                                setViewMode("all");
                              }}
                              className="text-[#2f81f7] hover:underline cursor-pointer"
                            >
                              cmux
                            </button>{" "}
                            preview system
                          </p>
                        </div>
                      </div>

                      <div className="flex items-center gap-1 mt-2">
                        <button
                          onClick={() => setThumbsUpActive(!thumbsUpActive)}
                          className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full border text-xs transition-colors ${thumbsUpActive
                              ? "border-[#2f81f7] bg-[#388bfd1a] text-[#2f81f7]"
                              : "border-[#30363d] bg-[#21262d] hover:bg-[#30363d]"
                            }`}
                        >
                          <span>👍</span>
                          <span
                            className={
                              thumbsUpActive
                                ? "text-[#2f81f7]"
                                : "text-[#7d8590]"
                            }
                          >
                            {thumbsUpActive ? 3 : 2}
                          </span>
                        </button>
                        <button
                          onClick={() => setRocketActive(!rocketActive)}
                          className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full border text-xs transition-colors ${rocketActive
                              ? "border-[#2f81f7] bg-[#388bfd1a] text-[#2f81f7]"
                              : "border-[#30363d] bg-[#21262d] hover:bg-[#30363d]"
                            }`}
                        >
                          <span>🚀</span>
                          <span
                            className={
                              rocketActive ? "text-[#2f81f7]" : "text-[#7d8590]"
                            }
                          >
                            {rocketActive ? 2 : 1}
                          </span>
                        </button>
                      </div>
                    </div>
                  </div>

                  {/* Merge button section - GitHub style */}
                  {!isPRMerged && (
                    <div className="mt-4 flex gap-4">
                      {/* PR merge icon */}
                      <div className="shrink-0 w-10 h-10 rounded-lg bg-[#238636] flex items-center justify-center">
                        <svg
                          className="h-5 w-5 text-white"
                          viewBox="0 0 16 16"
                          fill="currentColor"
                        >
                          <path d="M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z" />
                        </svg>
                      </div>
                      {/* Merge card */}
                      <div className="flex-1 rounded-md border border-[#238636] overflow-hidden">
                        {/* All checks passed */}
                        <div className="px-4 py-3 border-b border-[#30363d] flex items-center justify-between">
                          <div className="flex items-center gap-3">
                            <svg
                              className="h-5 w-5 text-[#238636]"
                              viewBox="0 0 16 16"
                              fill="none"
                              stroke="currentColor"
                              strokeWidth="1.5"
                            >
                              <circle cx="8" cy="8" r="6" />
                              <path
                                d="M5 8l2 2 4-4"
                                strokeLinecap="round"
                                strokeLinejoin="round"
                              />
                            </svg>
                            <div>
                              <p className="text-sm font-medium text-[#e6edf3]">
                                All checks have passed
                              </p>
                              <p className="text-xs text-[#7d8590]">
                                1 neutral, 5 successful checks
                              </p>
                            </div>
                          </div>
                          <ChevronDown className="h-4 w-4 text-[#7d8590]" />
                        </div>
                        {/* No conflicts */}
                        <div className="px-4 py-3 border-b border-[#30363d] flex items-center gap-3">
                          <svg
                            className="h-5 w-5 text-[#238636]"
                            viewBox="0 0 16 16"
                            fill="currentColor"
                          >
                            <path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.751.751 0 0 1 .018-1.042.751.751 0 0 1 1.042-.018L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0Z" />
                          </svg>
                          <div>
                            <p className="text-sm font-medium text-[#e6edf3]">
                              No conflicts with base branch
                            </p>
                            <p className="text-xs text-[#7d8590]">
                              Merging can be performed automatically.
                            </p>
                          </div>
                        </div>
                        {/* Merge button row */}
                        <div className="px-4 py-3 bg-[#161b22] flex items-center gap-3">
                          <div className="flex">
                            <button
                              onClick={() => setIsPRMerged(true)}
                              className="px-4 py-1.5 bg-[#238636] hover:bg-[#2ea043] text-white text-sm font-medium rounded-l-md transition-colors"
                            >
                              Merge pull request
                            </button>
                            <button className="px-2 py-1.5 bg-[#238636] hover:bg-[#2ea043] text-white border-l border-[#2ea043] rounded-r-md transition-colors">
                              <ChevronDown className="h-4 w-4" />
                            </button>
                          </div>
                          <span className="text-xs text-[#7d8590]">
                            You can also merge this with the command line.{" "}
                            <span className="text-[#2f81f7] hover:underline cursor-pointer">
                              View command line instructions.
                            </span>
                          </span>
                        </div>
                      </div>
                    </div>
                  )}

                  {isPRMerged && (
                    <div className="mt-4 flex gap-4">
                      {/* Purple merge icon */}
                      <div className="shrink-0 w-10 h-10 rounded-full bg-[#8957e5] flex items-center justify-center">
                        <svg
                          className="h-5 w-5 text-white"
                          viewBox="0 0 16 16"
                          fill="currentColor"
                        >
                          <path d="M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z" />
                        </svg>
                      </div>
                      {/* Merged card */}
                      <div className="flex-1 rounded-md border border-[#8957e5] bg-[#0d1117] p-4">
                        <p className="text-sm font-semibold text-[#e6edf3]">
                          Pull request successfully merged and closed
                        </p>
                        <p className="text-sm text-[#7d8590] mt-1">
                          You&apos;re all set — the branch has been merged.
                        </p>
                      </div>
                    </div>
                  )}
                </div>
              )}

              {activePRTab === "commits" && (
                <div className="px-6 py-4">
                  <div className="space-y-0">
                    {/* Commit group header */}
                    <div className="flex items-center gap-2 py-2 text-sm text-[#7d8590]">
                      <svg
                        className="h-4 w-4"
                        viewBox="0 0 16 16"
                        fill="currentColor"
                      >
                        <path d="M11.93 8.5a4.002 4.002 0 0 1-7.86 0H.75a.75.75 0 0 1 0-1.5h3.32a4.002 4.002 0 0 1 7.86 0h3.32a.75.75 0 0 1 0 1.5Zm-1.43-.75a2.5 2.5 0 1 0-5 0 2.5 2.5 0 0 0 5 0Z" />
                      </svg>
                      <span>Commits on Dec 2, 2025</span>
                    </div>

                    {/* Commits list */}
                    {[
                      {
                        sha: "ee59b00",
                        msg: "fix: reuse preview config component in wizard",
                        time: "yesterday",
                      },
                      {
                        sha: "a1b2c3d",
                        msg: "refactor: extract shared form components",
                        time: "yesterday",
                      },
                      {
                        sha: "d4e5f6g",
                        msg: "feat: add collapsible sections for wizard steps",
                        time: "yesterday",
                      },
                      {
                        sha: "h7i8j9k",
                        msg: "fix: sync state between initial and wizard views",
                        time: "yesterday",
                      },
                      {
                        sha: "l0m1n2o",
                        msg: "chore: clean up unused imports",
                        time: "yesterday",
                      },
                      {
                        sha: "p3q4r5s",
                        msg: "style: improve spacing in wizard sidebar",
                        time: "2 days ago",
                      },
                      {
                        sha: "t6u7v8w",
                        msg: "fix: handle edge case in env var parsing",
                        time: "2 days ago",
                      },
                      {
                        sha: "x9y0z1a",
                        msg: "feat: add framework preset autofill",
                        time: "2 days ago",
                      },
                      {
                        sha: "b2c3d4e",
                        msg: "refactor: consolidate script input components",
                        time: "2 days ago",
                      },
                      {
                        sha: "f5g6h7i",
                        msg: "fix: wizard step navigation",
                        time: "2 days ago",
                      },
                      {
                        sha: "j8k9l0m",
                        msg: "chore: update dependencies",
                        time: "3 days ago",
                      },
                      {
                        sha: "n1o2p3q",
                        msg: "feat: add save configuration button",
                        time: "3 days ago",
                      },
                      {
                        sha: "r4s5t6u",
                        msg: "style: dark mode improvements",
                        time: "3 days ago",
                      },
                      {
                        sha: "v7w8x9y",
                        msg: "initial: setup preview config wizard",
                        time: "3 days ago",
                      },
                    ].map((commit) => (
                      <div
                        key={commit.sha}
                        className="flex items-center gap-3 py-2 border-t border-[#21262d] hover:bg-[#161b22] -mx-2 px-2 rounded"
                      >
                        <Image
                          src="https://avatars.githubusercontent.com/u/38676809?v=4"
                          alt="austinywang"
                          width={24}
                          height={24}
                          className="rounded-full"
                          unoptimized
                        />
                        <div className="flex-1 min-w-0">
                          <span className="text-sm text-[#e6edf3] hover:text-[#2f81f7] cursor-pointer truncate block">
                            {commit.msg}
                          </span>
                        </div>
                        <code className="text-xs text-[#2f81f7] font-mono hover:underline cursor-pointer">
                          {commit.sha}
                        </code>
                        <span className="text-xs text-[#7d8590] shrink-0">
                          {commit.time}
                        </span>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {activePRTab === "checks" && (
                <div className="px-6 py-4">
                  {/* All checks passed banner */}
                  <div className="flex items-center gap-3 p-4 rounded-md border border-[#238636] bg-[#2ea04326] mb-4">
                    <svg
                      className="h-6 w-6 text-[#3fb950]"
                      viewBox="0 0 16 16"
                      fill="currentColor"
                    >
                      <path d="M8 16A8 8 0 1 1 8 0a8 8 0 0 1 0 16Zm3.78-9.72a.751.751 0 0 0-.018-1.042.751.751 0 0 0-1.042-.018L6.75 9.19 5.28 7.72a.751.751 0 0 0-1.042.018.751.751 0 0 0-.018 1.042l2 2a.75.75 0 0 0 1.06 0Z" />
                    </svg>
                    <div>
                      <div className="text-sm font-semibold text-[#e6edf3]">
                        All checks have passed
                      </div>
                      <div className="text-xs text-[#7d8590]">
                        4 successful checks
                      </div>
                    </div>
                  </div>

                  {/* Checks list */}
                  <div className="border border-[#30363d] rounded-md overflow-hidden">
                    {[
                      { name: "build", desc: "Build succeeded", time: "45s" },
                      { name: "lint", desc: "ESLint passed", time: "12s" },
                      {
                        name: "typecheck",
                        desc: "TypeScript compilation succeeded",
                        time: "28s",
                      },
                      {
                        name: "test",
                        desc: "All tests passed (142 tests)",
                        time: "1m 23s",
                      },
                    ].map((check, i) => (
                      <div
                        key={check.name}
                        className={clsx(
                          "flex items-center gap-3 px-4 py-3",
                          i > 0 && "border-t border-[#21262d]"
                        )}
                      >
                        <svg
                          className="h-4 w-4 text-[#3fb950]"
                          viewBox="0 0 16 16"
                          fill="currentColor"
                        >
                          <path d="M8 16A8 8 0 1 1 8 0a8 8 0 0 1 0 16Zm3.78-9.72a.751.751 0 0 0-.018-1.042.751.751 0 0 0-1.042-.018L6.75 9.19 5.28 7.72a.751.751 0 0 0-1.042.018.751.751 0 0 0-.018 1.042l2 2a.75.75 0 0 0 1.06 0Z" />
                        </svg>
                        <div className="flex-1">
                          <div className="text-sm text-[#e6edf3]">
                            {check.name}
                          </div>
                          <div className="text-xs text-[#7d8590]">
                            {check.desc}
                          </div>
                        </div>
                        <span className="text-xs text-[#7d8590]">
                          {check.time}
                        </span>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {activePRTab === "files" && (
                <div className="px-6 py-4">
                  {/* Files changed header */}
                  <div className="flex items-center gap-4 pb-4 border-b border-[#30363d] mb-4">
                    <span className="text-sm text-[#e6edf3]">
                      Showing <strong>2 changed files</strong> with{" "}
                      <span className="text-[#3fb950]">73 additions</span> and{" "}
                      <span className="text-[#f85149]">16 deletions</span>
                    </span>
                  </div>

                  {/* File diffs */}
                  <div className="space-y-4">
                    {/* File 1 */}
                    <div className="border border-[#30363d] rounded-md overflow-hidden">
                      <div className="flex items-center gap-2 px-4 py-2 bg-[#161b22] border-b border-[#30363d]">
                        <svg
                          className="h-4 w-4 text-[#7d8590]"
                          viewBox="0 0 16 16"
                          fill="currentColor"
                        >
                          <path d="M2 1.75C2 .784 2.784 0 3.75 0h6.586c.464 0 .909.184 1.237.513l2.914 2.914c.329.328.513.773.513 1.237v9.586A1.75 1.75 0 0 1 13.25 16h-9.5A1.75 1.75 0 0 1 2 14.25Zm1.75-.25a.25.25 0 0 0-.25.25v12.5c0 .138.112.25.25.25h9.5a.25.25 0 0 0 .25-.25V6h-2.75A1.75 1.75 0 0 1 9 4.25V1.5Zm6.75.062V4.25c0 .138.112.25.25.25h2.688Z" />
                        </svg>
                        <span className="text-sm text-[#e6edf3]">
                          apps/client/src/components/TaskItem.tsx
                        </span>
                        <span className="ml-auto text-xs">
                          <span className="text-[#3fb950]">+28</span>
                          <span className="text-[#7d8590] mx-1">−</span>
                          <span className="text-[#f85149]">4</span>
                        </span>
                      </div>
                      <div className="text-[11px] font-mono overflow-x-auto">
                        <div className="px-2 py-0.5 text-[#7d8590] bg-[#161b22]">
                          @@ -1,12 +1,15 @@
                        </div>
                        <div className="flex">
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#0d1117]">
                            1
                          </span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#0d1117]">
                            1
                          </span>
                          <span className="flex-1 px-2 text-[#e6edf3]">
                            import {"{"} useState {"}"} from &quot;react&quot;;
                          </span>
                        </div>
                        <div className="flex">
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#0d1117]">
                            2
                          </span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#0d1117]">
                            2
                          </span>
                          <span className="flex-1 px-2 text-[#e6edf3]">
                            import {"{"} useQuery {"}"} from
                            &quot;convex/react&quot;;
                          </span>
                        </div>
                        <div className="flex bg-[#f851491a]">
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#f851494d]">
                            3
                          </span>
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="flex-1 px-2 text-[#f85149]">
                            -import {"{"} api {"}"} from &quot;@/convex&quot;;
                          </span>
                        </div>
                        <div className="flex bg-[#2ea04326]">
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#2ea0434d]">
                            3
                          </span>
                          <span className="flex-1 px-2 text-[#3fb950]">
                            +import {"{"} api {"}"} from
                            &quot;@cmux/convex/api&quot;;
                          </span>
                        </div>
                        <div className="flex bg-[#2ea04326]">
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#2ea0434d]">
                            4
                          </span>
                          <span className="flex-1 px-2 text-[#3fb950]">
                            +import {"{"} isFakeConvexId {"}"} from
                            &quot;@/lib/utils&quot;;
                          </span>
                        </div>
                        <div className="flex">
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#0d1117]">
                            4
                          </span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#0d1117]">
                            5
                          </span>
                          <span className="flex-1 px-2 text-[#e6edf3]">
                            import {"{"} TaskTree {"}"} from
                            &quot;./TaskTree&quot;;
                          </span>
                        </div>
                      </div>
                    </div>

                    {/* File 2 */}
                    <div className="border border-[#30363d] rounded-md overflow-hidden">
                      <div className="flex items-center gap-2 px-4 py-2 bg-[#161b22] border-b border-[#30363d]">
                        <svg
                          className="h-4 w-4 text-[#3fb950]"
                          viewBox="0 0 16 16"
                          fill="currentColor"
                        >
                          <path d="M2 1.75C2 .784 2.784 0 3.75 0h6.586c.464 0 .909.184 1.237.513l2.914 2.914c.329.328.513.773.513 1.237v9.586A1.75 1.75 0 0 1 13.25 16h-9.5A1.75 1.75 0 0 1 2 14.25Zm1.75-.25a.25.25 0 0 0-.25.25v12.5c0 .138.112.25.25.25h9.5a.25.25 0 0 0 .25-.25V6h-2.75A1.75 1.75 0 0 1 9 4.25V1.5Zm6.75.062V4.25c0 .138.112.25.25.25h2.688Z" />
                        </svg>
                        <span className="text-sm text-[#e6edf3]">
                          apps/client/src/lib/utils.ts
                        </span>
                        <span className="px-1.5 py-0.5 rounded text-[10px] bg-[#2ea04326] text-[#3fb950] border border-[#2ea04366]">
                          Added
                        </span>
                        <span className="ml-auto text-xs">
                          <span className="text-[#3fb950]">+45</span>
                          <span className="text-[#7d8590] mx-1">−</span>
                          <span className="text-[#7d8590]">0</span>
                        </span>
                      </div>
                      <div className="text-[11px] font-mono overflow-x-auto">
                        <div className="px-2 py-0.5 text-[#7d8590] bg-[#161b22]">
                          @@ -0,0 +1,45 @@
                        </div>
                        <div className="flex bg-[#2ea04326]">
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#2ea0434d]">
                            1
                          </span>
                          <span className="flex-1 px-2 text-[#3fb950]">
                            +export function isFakeConvexId(id: string): boolean{" "}
                            {"{"}
                          </span>
                        </div>
                        <div className="flex bg-[#2ea04326]">
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#2ea0434d]">
                            2
                          </span>
                          <span className="flex-1 px-2 text-[#3fb950]">
                            + return id.startsWith(&quot;fake_&quot;);
                          </span>
                        </div>
                        <div className="flex bg-[#2ea04326]">
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#2ea0434d]">
                            3
                          </span>
                          <span className="flex-1 px-2 text-[#3fb950]">
                            +{"}"}
                          </span>
                        </div>
                        <div className="flex bg-[#2ea04326]">
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#2ea0434d]">
                            4
                          </span>
                          <span className="flex-1 px-2 text-[#3fb950]">+</span>
                        </div>
                        <div className="flex bg-[#2ea04326]">
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#2ea0434d]">
                            5
                          </span>
                          <span className="flex-1 px-2 text-[#3fb950]">
                            +export function rewriteLocalId(id: string) {"{"}
                          </span>
                        </div>
                        <div className="flex bg-[#2ea04326]">
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#2ea0434d]">
                            6
                          </span>
                          <span className="flex-1 px-2 text-[#3fb950]">
                            + return id.replace(&quot;fake_&quot;,
                            &quot;&quot;);
                          </span>
                        </div>
                        <div className="flex bg-[#2ea04326]">
                          <span className="w-8 text-right pr-2 select-none bg-[#0d1117]"></span>
                          <span className="w-8 text-[#7d8590] text-right pr-2 select-none bg-[#2ea0434d]">
                            7
                          </span>
                          <span className="flex-1 px-2 text-[#3fb950]">
                            +{"}"}
                          </span>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>
        ) : (
          <div
            ref={containerRef}
            className="bg-neutral-900 flex flex-1 min-h-0"
          >
            {/* Left Sidebar - cmux style */}
            <div className="w-[280px] bg-neutral-950 border-r border-neutral-800 flex flex-col shrink-0">
              {/* Header with logo */}
              <div className="h-[38px] flex items-center px-3 shrink-0">
                <CmuxLogo height={28} wordmarkText="cmux" />
                <div className="ml-auto">
                  <div className="w-[25px] h-[25px] border border-neutral-800 rounded-lg flex items-center justify-center cursor-not-allowed">
                    <Plus className="w-4 h-4 text-neutral-400" />
                  </div>
                </div>
              </div>

              {/* Navigation items */}
              <nav className="flex-1 overflow-y-auto">
                <ul className="flex flex-col gap-px">
                  <li>
                    <div className="mx-1 flex items-center gap-2 rounded-sm pl-2 ml-2 pr-3 py-1 text-[13px] text-neutral-400 cursor-not-allowed">
                      <Home className="w-4 h-4 text-neutral-400" />
                      <span>Home</span>
                    </div>
                  </li>
                  <li>
                    <div className="mx-1 flex items-center gap-2 rounded-sm pl-2 ml-2 pr-3 py-1 text-[13px] text-neutral-400 cursor-not-allowed">
                      <Server className="w-4 h-4 text-neutral-400" />
                      <span>Environments</span>
                    </div>
                  </li>
                  <li>
                    <div className="mx-1 flex items-center gap-2 rounded-sm pl-2 ml-2 pr-3 py-1 text-[13px] text-neutral-400 cursor-not-allowed">
                      <Settings className="w-4 h-4 text-neutral-400" />
                      <span>Settings</span>
                    </div>
                  </li>
                </ul>

                {/* Previews section */}
                <div className="mt-4 flex flex-col">
                  <div className="pl-2 ml-2 pr-3 py-0.5 text-[12px] font-medium text-neutral-300 cursor-pointer hover:bg-neutral-800/45 rounded-sm mx-1">
                    Previews
                  </div>
                  <div className="pt-px space-y-px">
                    {/* Preview task 1 - PR #1168 */}
                    <div className="space-y-px">
                      <PreviewItemButton
                        title="Preview screenshots for PR #1168"
                        subtitle="main • manaflow-ai/cmux"
                        isExpanded={expandedTasks.has("task-1")}
                        isSelected={selectedTaskId === "task-1"}
                        isPRMerged={isPRMerged}
                        onToggleExpand={() => toggleTaskExpanded("task-1")}
                        onClick={() => selectTask("task-1")}
                      />

                      {expandedTasks.has("task-1") && (
                        <div>
                          <div
                            onClick={() => selectTask("task-1")}
                            className={clsx(
                              "w-full flex items-center py-[3px] pr-2 text-[13px] text-neutral-100 hover:bg-neutral-800/45 cursor-pointer rounded-sm mt-px",
                              selectedTaskId === "task-1" && viewMode === "all"
                                ? "bg-neutral-800/50"
                                : "text-neutral-300"
                            )}
                            style={{ paddingLeft: "28px" }}
                          >
                            <button
                              onClick={(e) => {
                                e.preventDefault();
                                e.stopPropagation();
                                toggleTaskExpanded("task-1-run");
                              }}
                              onMouseDown={(e) => e.stopPropagation()}
                              className="shrink-0 grid place-content-center rounded cursor-default transition-colors size-4 mr-2"
                            >
                              <ChevronRight
                                className={clsx(
                                  "w-3 h-3 text-neutral-500 transition-transform pointer-events-none",
                                  expandedTasks.has("task-1-run") && "rotate-90"
                                )}
                              />
                            </button>
                            <span className="truncate">
                              screenshot-collector
                            </span>
                            {isPRMerged ? (
                              <svg
                                className="w-3 h-3 text-[#8957e5] shrink-0 ml-auto"
                                viewBox="0 0 16 16"
                                fill="currentColor"
                              >
                                <path d="M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z" />
                              </svg>
                            ) : (
                              <CheckCircle2 className="w-3 h-3 text-green-500 shrink-0 ml-auto" />
                            )}
                          </div>
                          {expandedTasks.has("task-1-run") && (
                            <>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-1");
                                  setViewMode("workspace");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-1" &&
                                    viewMode === "workspace"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <VSCodeIcon className="w-3 h-3 shrink-0 grayscale opacity-60" />
                                <span>VS Code</span>
                              </button>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-1");
                                  setViewMode("gitDiff");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-1" &&
                                    viewMode === "gitDiff"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <GitCompareIcon className="w-3 h-3 shrink-0" />
                                <span>Git diff</span>
                              </button>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-1");
                                  setViewMode("browser");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-1" &&
                                    viewMode === "browser"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <Monitor className="w-3 h-3 shrink-0" />
                                <span>Browser</span>
                              </button>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-1");
                                  setViewMode("terminals");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-1" &&
                                    viewMode === "terminals"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <TerminalSquare className="w-3 h-3 shrink-0" />
                                <span>Terminals</span>
                              </button>
                            </>
                          )}
                        </div>
                      )}
                    </div>

                    {/* Preview task 2 - PR #1142 */}
                    <div className="space-y-px">
                      <PreviewItemButton
                        title="Preview screenshots for PR #1142"
                        subtitle="feat/dark-mode • manaflow-ai/cmux"
                        isExpanded={expandedTasks.has("task-2")}
                        isSelected={selectedTaskId === "task-2"}
                        onToggleExpand={() => toggleTaskExpanded("task-2")}
                        onClick={() => selectTask("task-2")}
                      />

                      {expandedTasks.has("task-2") && (
                        <div>
                          <div
                            onClick={() => selectTask("task-2")}
                            className={clsx(
                              "w-full flex items-center py-[3px] pr-2 text-[13px] text-neutral-100 hover:bg-neutral-800/45 cursor-pointer rounded-sm mt-px",
                              selectedTaskId === "task-2" && viewMode === "all"
                                ? "bg-neutral-800/50"
                                : "text-neutral-300"
                            )}
                            style={{ paddingLeft: "28px" }}
                          >
                            <button
                              onClick={(e) => {
                                e.preventDefault();
                                e.stopPropagation();
                                toggleTaskExpanded("task-2-run");
                              }}
                              onMouseDown={(e) => e.stopPropagation()}
                              className="shrink-0 grid place-content-center rounded cursor-default transition-colors size-4 mr-2"
                            >
                              <ChevronRight
                                className={clsx(
                                  "w-3 h-3 text-neutral-500 transition-transform pointer-events-none",
                                  expandedTasks.has("task-2-run") && "rotate-90"
                                )}
                              />
                            </button>
                            <span className="truncate">
                              screenshot-collector
                            </span>
                            <CheckCircle2 className="w-3 h-3 text-green-500 shrink-0 ml-auto" />
                          </div>
                          {expandedTasks.has("task-2-run") && (
                            <>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-2");
                                  setViewMode("workspace");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-2" &&
                                    viewMode === "workspace"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <VSCodeIcon className="w-3 h-3 shrink-0 grayscale opacity-60" />
                                <span>VS Code</span>
                              </button>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-2");
                                  setViewMode("gitDiff");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-2" &&
                                    viewMode === "gitDiff"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <GitCompareIcon className="w-3 h-3 shrink-0" />
                                <span>Git diff</span>
                              </button>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-2");
                                  setViewMode("browser");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-2" &&
                                    viewMode === "browser"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <Monitor className="w-3 h-3 shrink-0" />
                                <span>Browser</span>
                              </button>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-2");
                                  setViewMode("terminals");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-2" &&
                                    viewMode === "terminals"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <TerminalSquare className="w-3 h-3 shrink-0" />
                                <span>Terminals</span>
                              </button>
                            </>
                          )}
                        </div>
                      )}
                    </div>

                    {/* Preview task 3 - PR #1098 */}
                    <div className="space-y-px">
                      <PreviewItemButton
                        title="Preview screenshots for PR #1098"
                        subtitle="fix/auth-redirect • manaflow-ai/cmux"
                        isExpanded={expandedTasks.has("task-3")}
                        isSelected={selectedTaskId === "task-3"}
                        onToggleExpand={() => toggleTaskExpanded("task-3")}
                        onClick={() => selectTask("task-3")}
                      />

                      {expandedTasks.has("task-3") && (
                        <div>
                          <div
                            onClick={() => selectTask("task-3")}
                            className={clsx(
                              "w-full flex items-center py-[3px] pr-2 text-[13px] text-neutral-100 hover:bg-neutral-800/45 cursor-pointer rounded-sm mt-px",
                              selectedTaskId === "task-3" && viewMode === "all"
                                ? "bg-neutral-800/50"
                                : "text-neutral-300"
                            )}
                            style={{ paddingLeft: "28px" }}
                          >
                            <button
                              onClick={(e) => {
                                e.preventDefault();
                                e.stopPropagation();
                                toggleTaskExpanded("task-3-run");
                              }}
                              onMouseDown={(e) => e.stopPropagation()}
                              className="shrink-0 grid place-content-center rounded cursor-default transition-colors size-4 mr-2"
                            >
                              <ChevronRight
                                className={clsx(
                                  "w-3 h-3 text-neutral-500 transition-transform pointer-events-none",
                                  expandedTasks.has("task-3-run") && "rotate-90"
                                )}
                              />
                            </button>
                            <span className="truncate">
                              screenshot-collector
                            </span>
                            <CheckCircle2 className="w-3 h-3 text-green-500 shrink-0 ml-auto" />
                          </div>
                          {expandedTasks.has("task-3-run") && (
                            <>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-3");
                                  setViewMode("workspace");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-3" &&
                                    viewMode === "workspace"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <VSCodeIcon className="w-3 h-3 shrink-0 grayscale opacity-60" />
                                <span>VS Code</span>
                              </button>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-3");
                                  setViewMode("gitDiff");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-3" &&
                                    viewMode === "gitDiff"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <GitCompareIcon className="w-3 h-3 shrink-0" />
                                <span>Git diff</span>
                              </button>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-3");
                                  setViewMode("browser");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-3" &&
                                    viewMode === "browser"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <Monitor className="w-3 h-3 shrink-0" />
                                <span>Browser</span>
                              </button>
                              <button
                                onClick={() => {
                                  setSelectedTaskId("task-3");
                                  setViewMode("terminals");
                                }}
                                className={clsx(
                                  "w-full flex items-center gap-2 px-2 py-1 text-xs cursor-pointer text-left hover:bg-neutral-800/45 rounded-sm mt-px",
                                  selectedTaskId === "task-3" &&
                                    viewMode === "terminals"
                                    ? "bg-neutral-800/65 text-white"
                                    : "text-neutral-400"
                                )}
                                style={{ paddingLeft: "48px" }}
                              >
                                <TerminalSquare className="w-3 h-3 shrink-0" />
                                <span>Terminals</span>
                              </button>
                            </>
                          )}
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              </nav>
            </div>

            {/* Main Content Area */}
            <div className="flex-1 flex min-w-0 relative">
              {/* Three-panel layout when viewMode is "all" */}
              {viewMode === "all" && (
                <>
                  {/* Left: Workspace (VS Code) - resizable width */}
                  <div
                    className="bg-[#1e1e1e] border-r border-[#2d2d2d] flex flex-col min-w-0"
                    style={{ width: `${leftPanelWidth}%` }}
                  >
                    {/* Panel header */}
                    <div className="flex items-center gap-2 px-3 py-1.5 bg-[#252526] border-b border-[#2d2d2d]">
                      <VSCodeIcon className="h-4 w-4 grayscale opacity-60" />
                      <span className="text-xs text-[#cccccc]">Workspace</span>
                    </div>
                    {/* VS Code content */}
                    <div className="flex-1 flex min-h-0">
                      {/* File explorer sidebar */}
                      <div className="w-[160px] bg-[#252526] border-r border-[#2d2d2d] flex flex-col shrink-0">
                        <div className="px-2 py-1 text-[10px] font-semibold text-[#858585] uppercase tracking-wide">
                          Explorer
                        </div>
                        <div className="flex items-center gap-1 px-2 py-0.5 text-[11px] text-[#cccccc]">
                          <ChevronDown className="h-3 w-3" />
                          <span className="text-[10px]">cmux</span>
                        </div>
                        <div className="flex-1 overflow-y-auto text-[11px]">
                          {/* Root folders */}
                          {[
                            ".devcontainer",
                            ".github",
                            "apps",
                            "configs",
                            "packages",
                            "scripts",
                          ].map((folder) => (
                            <div
                              key={folder}
                              className="flex items-center gap-1 px-4 py-0.5 text-[#cccccc] hover:bg-[#2a2d2e] cursor-pointer"
                            >
                              <ChevronRight className="h-3 w-3 text-[#858585]" />
                              <Folder className="h-3 w-3 text-[#dcb67a]" />
                              <span>{folder}</span>
                            </div>
                          ))}
                          {/* Root files */}
                          {[
                            { name: ".gitignore", color: "#858585" },
                            { name: "package.json", color: "#cbcb41" },
                            { name: "README.md", color: "#519aba" },
                            { name: "tsconfig.json", color: "#519aba" },
                          ].map((file) => (
                            <div
                              key={file.name}
                              className="flex items-center gap-1 px-4 pl-[22px] py-0.5 text-[#cccccc] hover:bg-[#2a2d2e] cursor-pointer"
                            >
                              <FileText
                                className="h-3 w-3"
                                style={{ color: file.color }}
                              />
                              <span>{file.name}</span>
                            </div>
                          ))}
                        </div>
                      </div>
                      {/* Editor area */}
                      <div className="flex-1 flex flex-col min-w-0">
                        {/* Tabs */}
                        <VSCodeTabBar>
                          <VSCodeTab
                            icon={
                              <FileText className="h-3 w-3 text-[#858585]" />
                            }
                            label="LAUNCH.md"
                            isActive
                          />
                        </VSCodeTabBar>
                        {/* File content */}
                        <div className="flex-1 p-3 font-mono text-[11px] text-[#cccccc] overflow-auto">
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              1
                            </div>
                            <div className="text-[#6a9955]"># LAUNCH.md</div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              2
                            </div>
                            <div></div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              3
                            </div>
                            <div>Welcome to cmux!</div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              4
                            </div>
                            <div></div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              5
                            </div>
                            <div>Feel free to click around and explore!</div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              6
                            </div>
                            <div>- Explore preview tasks in the sidebar</div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              7
                            </div>
                            <div>- Check out the git diff view</div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              8
                            </div>
                            <div>- View the browser preview</div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              9
                            </div>
                            <div>
                              - Switch between tmux sessions in terminal
                            </div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              10
                            </div>
                            <div></div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              11
                            </div>
                            <div className="text-[#6a9955]">
                              ## What is cmux?
                            </div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              12
                            </div>
                            <div></div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              13
                            </div>
                            <div>
                              It&apos;s basically Linear for Claude Code
                            </div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              14
                            </div>
                            <div></div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              15
                            </div>
                            <div>also supports Codex, Gemini, & more...</div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              16
                            </div>
                            <div></div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              17
                            </div>
                            <div>it's a universal AI coding agent manager</div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              18
                            </div>
                            <div></div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              19
                            </div>
                            <div>
                              today, preview.new screenshot agent runs on cmux
                            </div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              0
                            </div>
                            <div></div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              19
                            </div>
                            <div className="text-[#6a9955]">
                              ## About Manaflow
                            </div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              20
                            </div>
                            <div></div>
                          </div>
                          <div className="flex">
                            <div className="pr-3 text-[#858585] select-none text-right w-8">
                              21
                            </div>
                            <div>We build interfaces to manage AI agents.</div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>

                  {/* Horizontal resize handle */}
                  <div
                    onMouseDown={startHorizontalResize}
                    className="w-1 cursor-col-resize bg-[#2d2d2d] hover:bg-[#007acc] active:bg-[#007acc] transition-colors shrink-0"
                    title="Drag to resize panels"
                  />

                  {/* Right: Browser + Git Diff stacked vertically */}
                  <div
                    className="flex flex-col min-w-0 relative"
                    style={{ width: `${100 - leftPanelWidth}%` }}
                  >
                    {/* Browser Panel */}
                    <div
                      className="bg-[#1e1e1e] flex flex-col"
                      style={{ height: `${topPanelHeight}%` }}
                    >
                      {/* Panel header */}
                      <div className="flex items-center gap-2 px-3 py-1.5 bg-[#252526] border-b border-[#2d2d2d]">
                        <Monitor className="h-4 w-4 text-[#858585]" />
                        <span className="text-xs text-[#cccccc]">Browser</span>
                      </div>
                      {/* Browser inside with VS Code style tabs */}
                      <div className="flex-1 flex flex-col bg-[#1e1e1e] overflow-hidden">
                        {/* VS Code style tab bar */}
                        <VSCodeTabBar>
                          <VSCodeTab
                            icon={<TabFavicon />}
                            label="cmux.dev"
                            isActive
                          />
                        </VSCodeTabBar>
                        {/* Browser content - cmux.dev landing page */}
                        <div className="flex-1 bg-[#030712] overflow-hidden">
                          <iframe
                            src="https://cmux.dev"
                            className={clsx(
                              "border-0 origin-top-left",
                              isResizing && "pointer-events-none"
                            )}
                            style={{
                              width: "200%",
                              height: "200%",
                              transform: "scale(0.5)",
                            }}
                            title="cmux landing page"
                          />
                        </div>
                      </div>
                    </div>

                    {/* Vertical resize handle */}
                    <div
                      onMouseDown={startVerticalResize}
                      className="h-1 cursor-row-resize bg-[#2d2d2d] hover:bg-[#007acc] active:bg-[#007acc] transition-colors shrink-0"
                      title="Drag to resize panels"
                    />

                    {/* Git Diff Panel */}
                    <div
                      className="bg-[#1e1e1e] flex flex-col"
                      style={{ height: `${100 - topPanelHeight}%` }}
                    >
                      <div className="flex items-center justify-between px-3 py-1.5 bg-[#252526] border-b border-[#2d2d2d] shrink-0">
                        <div className="flex items-center gap-2">
                          <GitBranch className="h-4 w-4 text-[#f97316]" />
                          <span className="text-xs text-[#cccccc]">
                            Git Diff
                          </span>
                          <span className="text-[10px] text-[#858585]">
                            3 files
                          </span>
                        </div>
                      </div>
                      <div
                        className="flex-1 flex flex-col min-h-0 overflow-y-auto"
                        style={{
                          scrollbarWidth: "thin",
                          scrollbarColor: "#30363d #1e1e1e",
                        }}
                      >
                        {/* File 1 - Modified */}
                        <div className="border-b border-[#2d2d2d]">
                          <button
                            onClick={() => toggleFileCollapse("file1")}
                            className="flex items-center gap-2 px-3 py-1.5 bg-[#252526] sticky top-0 w-full text-left hover:bg-[#2a2d2e] transition-colors"
                          >
                            {collapsedFiles.has("file1") ? (
                              <ChevronRight className="h-3 w-3 text-[#858585]" />
                            ) : (
                              <ChevronDown className="h-3 w-3 text-[#858585]" />
                            )}
                            <div className="w-2 h-2 rounded-full bg-yellow-500" />
                            <span className="text-[10px] text-[#cccccc] truncate flex-1">
                              apps/client/src/components/TaskItem.tsx
                            </span>
                            <span className="text-[9px] text-[#3fb950]">
                              +28
                            </span>
                            <span className="text-[9px] text-[#f85149]">
                              -4
                            </span>
                          </button>
                          {!collapsedFiles.has("file1") && (
                            <div className="text-[9px] font-mono">
                              <div className="px-2 py-0.5 text-[#858585] bg-[#1f2733] text-[8px]">
                                @@ -1,12 +1,15 @@
                              </div>
                              <div className="flex">
                                <span className="w-6 text-[#858585] text-right pr-2 select-none bg-[#1e1e1e]">
                                  1
                                </span>
                                <span className="w-6 text-[#858585] text-right pr-2 select-none bg-[#1e1e1e]">
                                  1
                                </span>
                                <span className="flex-1 px-2 text-[#cccccc]">
                                  import {"{"} useState {"}"} from
                                  &quot;react&quot;;
                                </span>
                              </div>
                              <div className="flex bg-[#f851491a]">
                                <span className="w-6 text-[#ff7b72] text-right pr-2 select-none bg-[#f851494d]">
                                  3
                                </span>
                                <span className="w-6 text-right pr-2 select-none bg-[#1e1e1e]"></span>
                                <span className="flex-1 px-2 text-[#f85149]">
                                  -import {"{"} api {"}"} from
                                  &quot;@/convex&quot;;
                                </span>
                              </div>
                              <div className="flex bg-[#2ea04326]">
                                <span className="w-6 text-right pr-2 select-none bg-[#1e1e1e]"></span>
                                <span className="w-6 text-[#7ee787] text-right pr-2 select-none bg-[#3fb9504d]">
                                  3
                                </span>
                                <span className="flex-1 px-2 text-[#3fb950]">
                                  +import {"{"} api {"}"} from
                                  &quot;@cmux/convex/api&quot;;
                                </span>
                              </div>
                              <div className="px-2 py-0.5 text-[#858585] bg-[#1f2733] text-[8px]">
                                ... 18 unchanged lines ...
                              </div>
                            </div>
                          )}
                        </div>

                        {/* File 2 - Added */}
                        <div className="border-b border-[#2d2d2d]">
                          <button
                            onClick={() => toggleFileCollapse("file2")}
                            className="flex items-center gap-2 px-3 py-1.5 bg-[#252526] sticky top-0 w-full text-left hover:bg-[#2a2d2e] transition-colors"
                          >
                            {collapsedFiles.has("file2") ? (
                              <ChevronRight className="h-3 w-3 text-[#858585]" />
                            ) : (
                              <ChevronDown className="h-3 w-3 text-[#858585]" />
                            )}
                            <div className="w-2 h-2 rounded-full bg-green-500" />
                            <span className="text-[10px] text-[#cccccc] truncate flex-1">
                              apps/client/src/lib/utils.ts
                            </span>
                            <span className="text-[9px] text-[#3fb950]">
                              +45
                            </span>
                            <span className="text-[9px] text-[#858585]">
                              -0
                            </span>
                          </button>
                          {!collapsedFiles.has("file2") && (
                            <div className="text-[9px] font-mono">
                              <div className="px-2 py-0.5 text-[#858585] bg-[#1f2733] text-[8px]">
                                @@ -0,0 +1,45 @@
                              </div>
                              <div className="flex bg-[#2ea04326]">
                                <span className="w-6 text-right pr-2 select-none bg-[#1e1e1e]"></span>
                                <span className="w-6 text-[#7ee787] text-right pr-2 select-none bg-[#3fb9504d]">
                                  1
                                </span>
                                <span className="flex-1 px-2 text-[#3fb950]">
                                  +export function isFakeConvexId(id: string):
                                  boolean {"{"}
                                </span>
                              </div>
                              <div className="flex bg-[#2ea04326]">
                                <span className="w-6 text-right pr-2 select-none bg-[#1e1e1e]"></span>
                                <span className="w-6 text-[#7ee787] text-right pr-2 select-none bg-[#3fb9504d]">
                                  2
                                </span>
                                <span className="flex-1 px-2 text-[#3fb950]">
                                  + return id.startsWith(&quot;fake_&quot;);
                                </span>
                              </div>
                              <div className="flex bg-[#2ea04326]">
                                <span className="w-6 text-right pr-2 select-none bg-[#1e1e1e]"></span>
                                <span className="w-6 text-[#7ee787] text-right pr-2 select-none bg-[#3fb9504d]">
                                  3
                                </span>
                                <span className="flex-1 px-2 text-[#3fb950]">
                                  +{"}"}
                                </span>
                              </div>
                              <div className="px-2 py-0.5 text-[#858585] bg-[#1f2733] text-[8px]">
                                ... 42 more lines ...
                              </div>
                            </div>
                          )}
                        </div>

                        {/* File 3 - Deleted (starts collapsed) */}
                        <div className="border-b border-[#2d2d2d]">
                          <button
                            onClick={() => toggleFileCollapse("file3")}
                            className="flex items-center gap-2 px-3 py-1.5 bg-[#252526] sticky top-0 w-full text-left hover:bg-[#2a2d2e] transition-colors"
                          >
                            {collapsedFiles.has("file3") ? (
                              <ChevronRight className="h-3 w-3 text-[#858585]" />
                            ) : (
                              <ChevronDown className="h-3 w-3 text-[#858585]" />
                            )}
                            <div className="w-2 h-2 rounded-full bg-red-500" />
                            <span className="text-[10px] text-[#cccccc] truncate flex-1">
                              apps/client/src/legacy/helpers.ts
                            </span>
                            <span className="text-[9px] text-[#858585]">
                              +0
                            </span>
                            <span className="text-[9px] text-[#f85149]">
                              -12
                            </span>
                          </button>
                          {!collapsedFiles.has("file3") && (
                            <div className="text-[9px] font-mono">
                              <div className="px-2 py-0.5 text-[#858585] bg-[#1f2733] text-[8px]">
                                @@ -1,12 +0,0 @@
                              </div>
                              <div className="flex bg-[#f851491a]">
                                <span className="w-6 text-[#ff7b72] text-right pr-2 select-none bg-[#f851494d]">
                                  1
                                </span>
                                <span className="w-6 text-right pr-2 select-none bg-[#1e1e1e]"></span>
                                <span className="flex-1 px-2 text-[#f85149]">
                                  -// Legacy helper functions
                                </span>
                              </div>
                              <div className="flex bg-[#f851491a]">
                                <span className="w-6 text-[#ff7b72] text-right pr-2 select-none bg-[#f851494d]">
                                  2
                                </span>
                                <span className="w-6 text-right pr-2 select-none bg-[#1e1e1e]"></span>
                                <span className="flex-1 px-2 text-[#f85149]">
                                  -export function oldHelper() {"{"}
                                </span>
                              </div>
                              <div className="px-2 py-0.5 text-[#858585] bg-[#1f2733] text-[8px]">
                                ... 10 more lines ...
                              </div>
                            </div>
                          )}
                        </div>
                      </div>
                    </div>
                  </div>
                </>
              )}

              {/* Single panel: Workspace (VS Code) */}
              {viewMode === "workspace" && (
                <div className="flex-1 bg-[#1e1e1e] flex flex-col">
                  {/* Panel header */}
                  <div className="flex items-center gap-2 px-3 py-1.5 bg-[#252526] border-b border-[#2d2d2d]">
                    <VSCodeIcon className="h-4 w-4 grayscale opacity-60" />
                    <span className="text-xs text-[#cccccc]">Workspace</span>
                    <div className="ml-auto flex items-center gap-1">
                      <button
                        onClick={() => setViewMode("all")}
                        className="p-0.5 text-[#858585] hover:text-white hover:bg-[#3c3c3c] rounded text-[10px]"
                      >
                        Back to all
                      </button>
                    </div>
                  </div>
                  {/* VS Code content */}
                  <div className="flex-1 flex min-h-0">
                    {/* File explorer sidebar */}
                    <div className="w-[200px] bg-[#252526] border-r border-[#2d2d2d] flex flex-col shrink-0">
                      <div className="px-2 py-1 text-[10px] font-semibold text-[#858585] uppercase tracking-wide">
                        Explorer
                      </div>
                      <div className="flex items-center gap-1 px-2 py-0.5 text-[11px] text-[#cccccc] bg-[#37373d]">
                        <ChevronDown className="h-3 w-3" />
                        <span className="text-[10px]">cmux</span>
                      </div>
                      <div className="flex-1 overflow-y-auto text-[11px]">
                        {/* Root folders */}
                        {[
                          ".devcontainer",
                          ".github",
                          "apps",
                          "configs",
                          "packages",
                          "scripts",
                          "tests",
                        ].map((folder) => (
                          <div
                            key={folder}
                            className="flex items-center gap-1 px-4 py-0.5 text-[#cccccc] hover:bg-[#2a2d2e] cursor-pointer"
                          >
                            <ChevronRight className="h-3 w-3 text-[#858585]" />
                            <Folder className="h-3 w-3 text-[#dcb67a]" />
                            <span>{folder}</span>
                          </div>
                        ))}
                        {/* Root files */}
                        {[
                          { name: ".gitignore", color: "#858585" },
                          { name: "package.json", color: "#cbcb41" },
                          { name: "README.md", color: "#519aba" },
                          { name: "tsconfig.json", color: "#519aba" },
                        ].map((file) => (
                          <div
                            key={file.name}
                            className="flex items-center gap-1 px-4 pl-[22px] py-0.5 text-[#cccccc] hover:bg-[#2a2d2e] cursor-pointer"
                          >
                            <FileText
                              className="h-3 w-3"
                              style={{ color: file.color }}
                            />
                            <span>{file.name}</span>
                          </div>
                        ))}
                      </div>
                    </div>
                    {/* Editor area */}
                    <div className="flex-1 flex flex-col min-w-0">
                      {/* Tabs */}
                      <VSCodeTabBar>
                        <VSCodeTab
                          icon={<FileText className="h-3 w-3 text-[#858585]" />}
                          label="LAUNCH.md"
                          isActive
                        />
                      </VSCodeTabBar>
                      {/* File content */}
                      <div className="flex-1 p-4 font-mono text-[12px] text-[#cccccc] overflow-auto">
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            1
                          </div>
                          <div className="text-[#6a9955]"># LAUNCH.md</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            2
                          </div>
                          <div></div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            3
                          </div>
                          <div>Welcome to cmux!</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            4
                          </div>
                          <div></div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            5
                          </div>
                          <div>Feel free to click around and explore!</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            6
                          </div>
                          <div>- Explore preview tasks in the sidebar</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            7
                          </div>
                          <div>- Check out the git diff view</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            8
                          </div>
                          <div>- View the browser preview</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            9
                          </div>
                          <div>- There may be some Easter eggs</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            10
                          </div>
                          <div></div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            11
                          </div>
                          <div className="text-[#6a9955]">## What is cmux?</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            12
                          </div>
                          <div></div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            13
                          </div>
                          <div>It&apos;s basically Linear for Claude Code.</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            14
                          </div>
                          <div></div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            15
                          </div>
                          <div>A universal AI coding agent manager.</div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            16
                          </div>
                          <div></div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            17
                          </div>
                          <div className="text-[#6a9955]">
                            ## About Manaflow
                          </div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            18
                          </div>
                          <div></div>
                        </div>
                        <div className="flex">
                          <div className="pr-4 text-[#858585] select-none text-right w-10">
                            19
                          </div>
                          <div>We build interfaces to manage AI agents.</div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              )}

              {/* Single panel: Browser */}
              {viewMode === "browser" && (
                <div className="flex-1 bg-[#1e1e1e] flex flex-col">
                  {/* Panel header */}
                  <div className="flex items-center gap-2 px-3 py-1.5 bg-[#252526] border-b border-[#2d2d2d]">
                    <Monitor className="h-4 w-4 text-[#858585]" />
                    <span className="text-xs text-[#cccccc]">Browser</span>
                    <div className="ml-auto flex items-center gap-1">
                      <button
                        onClick={() => setViewMode("all")}
                        className="p-0.5 text-[#858585] hover:text-white hover:bg-[#3c3c3c] rounded text-[10px]"
                      >
                        Back to all
                      </button>
                    </div>
                  </div>
                  {/* Browser inside with VS Code style tabs */}
                  <div className="flex-1 flex flex-col bg-[#1e1e1e] overflow-hidden">
                    {/* VS Code style tab bar */}
                    <VSCodeTabBar>
                      <VSCodeTab
                        icon={<TabFavicon />}
                        label="cmux.dev"
                        isActive
                      />
                    </VSCodeTabBar>
                    {/* Browser content - cmux.dev landing page */}
                    <div className="flex-1 bg-[#030712] overflow-hidden">
                      <iframe
                        src="https://cmux.dev"
                        className={clsx(
                          "border-0 origin-top-left",
                          isResizing && "pointer-events-none"
                        )}
                        style={{
                          width: "200%",
                          height: "200%",
                          transform: "scale(0.5)",
                        }}
                        title="cmux landing page"
                      />
                    </div>
                  </div>
                </div>
              )}

              {/* Single panel: Git Diff */}
              {viewMode === "gitDiff" && (
                <div className="flex-1 bg-[#1e1e1e] flex flex-col">
                  <div className="flex items-center justify-between px-3 py-1.5 bg-[#252526] border-b border-[#2d2d2d] shrink-0">
                    <div className="flex items-center gap-2">
                      <GitBranch className="h-4 w-4 text-[#f97316]" />
                      <span className="text-xs text-[#cccccc]">Git Diff</span>
                      <span className="text-[10px] text-[#858585]">
                        3 files changed
                      </span>
                    </div>
                    <div className="flex items-center gap-1">
                      <button
                        onClick={() => setViewMode("all")}
                        className="p-0.5 text-[#858585] hover:text-white hover:bg-[#3c3c3c] rounded text-[10px]"
                      >
                        Back to all
                      </button>
                    </div>
                  </div>
                  <div
                    className="flex-1 flex flex-col min-h-0 overflow-y-auto"
                    style={{
                      scrollbarWidth: "thin",
                      scrollbarColor: "#30363d #1e1e1e",
                    }}
                  >
                    {/* File 1 - Modified */}
                    <div className="border-b border-[#2d2d2d]">
                      <button
                        onClick={() => toggleFileCollapse("file1")}
                        className="flex items-center gap-2 px-4 py-2 bg-[#252526] sticky top-0 w-full text-left hover:bg-[#2a2d2e] transition-colors"
                      >
                        {collapsedFiles.has("file1") ? (
                          <ChevronRight className="h-4 w-4 text-[#858585]" />
                        ) : (
                          <ChevronDown className="h-4 w-4 text-[#858585]" />
                        )}
                        <div className="w-2.5 h-2.5 rounded-full bg-yellow-500" />
                        <span className="text-sm text-[#cccccc] truncate flex-1">
                          apps/client/src/components/TaskItem.tsx
                        </span>
                        <span className="text-xs text-[#3fb950]">+28</span>
                        <span className="text-xs text-[#f85149]">-4</span>
                      </button>
                      {!collapsedFiles.has("file1") && (
                        <div className="text-[11px] font-mono">
                          <div className="px-4 py-1 text-[#858585] bg-[#1f2733]">
                            @@ -1,12 +1,15 @@
                          </div>
                          <div className="flex">
                            <span className="w-10 text-[#858585] text-right pr-3 select-none bg-[#1e1e1e]">
                              1
                            </span>
                            <span className="w-10 text-[#858585] text-right pr-3 select-none bg-[#1e1e1e]">
                              1
                            </span>
                            <span className="flex-1 px-4 text-[#cccccc]">
                              import {"{"} useState {"}"} from
                              &quot;react&quot;;
                            </span>
                          </div>
                          <div className="flex bg-[#f851491a]">
                            <span className="w-10 text-[#ff7b72] text-right pr-3 select-none bg-[#f851494d]">
                              3
                            </span>
                            <span className="w-10 text-right pr-3 select-none bg-[#1e1e1e]"></span>
                            <span className="flex-1 px-4 text-[#f85149]">
                              -import {"{"} api {"}"} from &quot;@/convex&quot;;
                            </span>
                          </div>
                          <div className="flex bg-[#2ea04326]">
                            <span className="w-10 text-right pr-3 select-none bg-[#1e1e1e]"></span>
                            <span className="w-10 text-[#7ee787] text-right pr-3 select-none bg-[#3fb9504d]">
                              3
                            </span>
                            <span className="flex-1 px-4 text-[#3fb950]">
                              +import {"{"} api {"}"} from
                              &quot;@cmux/convex/api&quot;;
                            </span>
                          </div>
                          <div className="px-4 py-1 text-[#858585] bg-[#1f2733]">
                            ... 18 unchanged lines ...
                          </div>
                        </div>
                      )}
                    </div>

                    {/* File 2 - Added */}
                    <div className="border-b border-[#2d2d2d]">
                      <button
                        onClick={() => toggleFileCollapse("file2")}
                        className="flex items-center gap-2 px-4 py-2 bg-[#252526] sticky top-0 w-full text-left hover:bg-[#2a2d2e] transition-colors"
                      >
                        {collapsedFiles.has("file2") ? (
                          <ChevronRight className="h-4 w-4 text-[#858585]" />
                        ) : (
                          <ChevronDown className="h-4 w-4 text-[#858585]" />
                        )}
                        <div className="w-2.5 h-2.5 rounded-full bg-green-500" />
                        <span className="text-sm text-[#cccccc] truncate flex-1">
                          apps/client/src/lib/utils.ts
                        </span>
                        <span className="text-xs text-[#3fb950]">+45</span>
                        <span className="text-xs text-[#858585]">-0</span>
                      </button>
                      {!collapsedFiles.has("file2") && (
                        <div className="text-[11px] font-mono">
                          <div className="px-4 py-1 text-[#858585] bg-[#1f2733]">
                            @@ -0,0 +1,45 @@
                          </div>
                          <div className="flex bg-[#2ea04326]">
                            <span className="w-10 text-right pr-3 select-none bg-[#1e1e1e]"></span>
                            <span className="w-10 text-[#7ee787] text-right pr-3 select-none bg-[#3fb9504d]">
                              1
                            </span>
                            <span className="flex-1 px-4 text-[#3fb950]">
                              +export function isFakeConvexId(id: string):
                              boolean {"{"}
                            </span>
                          </div>
                          <div className="flex bg-[#2ea04326]">
                            <span className="w-10 text-right pr-3 select-none bg-[#1e1e1e]"></span>
                            <span className="w-10 text-[#7ee787] text-right pr-3 select-none bg-[#3fb9504d]">
                              2
                            </span>
                            <span className="flex-1 px-4 text-[#3fb950]">
                              + return id.startsWith(&quot;fake_&quot;);
                            </span>
                          </div>
                          <div className="flex bg-[#2ea04326]">
                            <span className="w-10 text-right pr-3 select-none bg-[#1e1e1e]"></span>
                            <span className="w-10 text-[#7ee787] text-right pr-3 select-none bg-[#3fb9504d]">
                              3
                            </span>
                            <span className="flex-1 px-4 text-[#3fb950]">
                              +{"}"}
                            </span>
                          </div>
                          <div className="px-4 py-1 text-[#858585] bg-[#1f2733]">
                            ... 42 more lines ...
                          </div>
                        </div>
                      )}
                    </div>

                    {/* File 3 - Deleted */}
                    <div className="border-b border-[#2d2d2d]">
                      <button
                        onClick={() => toggleFileCollapse("file3")}
                        className="flex items-center gap-2 px-4 py-2 bg-[#252526] sticky top-0 w-full text-left hover:bg-[#2a2d2e] transition-colors"
                      >
                        {collapsedFiles.has("file3") ? (
                          <ChevronRight className="h-4 w-4 text-[#858585]" />
                        ) : (
                          <ChevronDown className="h-4 w-4 text-[#858585]" />
                        )}
                        <div className="w-2.5 h-2.5 rounded-full bg-red-500" />
                        <span className="text-sm text-[#cccccc] truncate flex-1">
                          apps/client/src/legacy/helpers.ts
                        </span>
                        <span className="text-xs text-[#858585]">+0</span>
                        <span className="text-xs text-[#f85149]">-12</span>
                      </button>
                      {!collapsedFiles.has("file3") && (
                        <div className="text-[11px] font-mono">
                          <div className="px-4 py-1 text-[#858585] bg-[#1f2733]">
                            @@ -1,12 +0,0 @@
                          </div>
                          <div className="flex bg-[#f851491a]">
                            <span className="w-10 text-[#ff7b72] text-right pr-3 select-none bg-[#f851494d]">
                              1
                            </span>
                            <span className="w-10 text-right pr-3 select-none bg-[#1e1e1e]"></span>
                            <span className="flex-1 px-4 text-[#f85149]">
                              -// Legacy helper functions
                            </span>
                          </div>
                          <div className="flex bg-[#f851491a]">
                            <span className="w-10 text-[#ff7b72] text-right pr-3 select-none bg-[#f851494d]">
                              2
                            </span>
                            <span className="w-10 text-right pr-3 select-none bg-[#1e1e1e]"></span>
                            <span className="flex-1 px-4 text-[#f85149]">
                              -export function oldHelper() {"{"}
                            </span>
                          </div>
                          <div className="px-4 py-1 text-[#858585] bg-[#1f2733]">
                            ... 10 more lines ...
                          </div>
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              )}

              {/* Single panel: Terminals */}
              {viewMode === "terminals" && (
                <div className="flex-1 bg-[#0d1117] flex flex-col">
                  {/* Terminal tab bar */}
                  <div className="flex items-center bg-[#161b22] border-b border-[#30363d] shrink-0">
                    <div className="flex items-center gap-2 px-3 py-1.5 bg-[#0d1117] border-r border-[#30363d] text-[#c9d1d9]">
                      <TerminalSquare className="h-3.5 w-3.5" />
                      <span className="text-xs">Terminal 1</span>
                    </div>
                    <div className="ml-auto pr-2">
                      <button
                        onClick={() => setViewMode("all")}
                        className="p-1 text-[#8b949e] hover:text-white hover:bg-[#30363d] rounded text-[10px]"
                      >
                        Back to all
                      </button>
                    </div>
                  </div>
                  {/* Terminal content */}
                  <div
                    className="flex-1 bg-[#0d1117] px-3 pt-2 pb-2 font-mono text-[11px] overflow-auto flex flex-col"
                    style={{
                      fontFamily: "'Menlo', 'Monaco', 'Courier New', monospace",
                    }}
                  >
                    <div className="flex-1 leading-[1.4]">
                      {/* Session 0: bunx - Claude Code output */}
                      {activeTmuxSession === 0 && (
                        <>
                          <div className="text-[#8b949e]">$ claude</div>
                          <div className="mt-2" />
                          <div className="text-[#58a6ff]">
                            ╭─────────────────────────────────────────╮
                          </div>
                          <div className="text-[#58a6ff]">
                            │{" "}
                            <span className="text-[#f0883e]">Claude Code</span>{" "}
                            v1.0.32 │
                          </div>
                          <div className="text-[#58a6ff]">
                            ╰─────────────────────────────────────────╯
                          </div>
                          <div className="mt-2" />
                          <div className="text-[#7ee787]">
                            ? What would you like to do?
                          </div>
                          <div className="mt-1" />
                          <div className="text-[#c9d1d9]">
                            {" "}
                            Fix the VS Code link visibility issue
                          </div>
                          <div className="mt-2" />
                          <div className="text-[#8b949e]">
                            Analyzing codebase...
                          </div>
                          <div className="text-[#8b949e]">
                            Found 3 relevant files
                          </div>
                          <div className="mt-2" />
                          <div className="text-[#7ee787]">
                            ✓ Updated apps/client/src/components/TaskItem.tsx
                          </div>
                          <div className="text-[#c9d1d9] pl-2">
                            Added isLocalWorkspace check to hasActiveVSCode
                          </div>
                          <div className="mt-2" />
                          <div className="flex items-center text-[#c9d1d9]">
                            <span className="text-[#f0883e]">&gt;</span>
                            <BlinkingCursor />
                          </div>
                        </>
                      )}
                      {/* Session 1: maintenance - bun install output */}
                      {activeTmuxSession === 1 && (
                        <>
                          <div className="text-[#8b949e]">
                            $ /var/tmp/cmux-scripts/maintenance.sh
                          </div>
                          <div className="text-[#7ee787]">
                            === Maintenance Script Started at 09:41 ===
                          </div>
                          <div className="mt-1" />
                          <div className="text-[#c9d1d9]">
                            /var/tmp/cmux-scripts/maintenance.sh:10&gt; bun i
                          </div>
                          <div className="text-[#58a6ff]">
                            bun install v1.3.3 (274e01c7)
                          </div>
                          <div className="mt-1" />
                          <div className="text-[#c9d1d9]">
                            Checked 3029 installs across 2077 packages (no
                            changes) [4.96s]
                          </div>
                          <div className="mt-1" />
                          <div className="text-[#8b949e]">
                            /var/tmp/cmux-scripts/maintenance.sh:11&gt; echo
                            &apos;=== Maintenance Script Completed ===&apos;
                          </div>
                          <div className="text-[#7ee787]">
                            === Maintenance Script Completed at 09:41 ===
                          </div>
                          <div className="mt-2" />
                          <div className="flex items-center text-[#c9d1d9]">
                            <span className="text-[#8b949e]">
                              root@localhost:~#
                            </span>
                            <BlinkingCursor />
                          </div>
                        </>
                      )}
                      {/* Session 2: dev - server logs */}
                      {activeTmuxSession === 2 && (
                        <>
                          <div>
                            <span className="text-[#f0883e]">[SERVER]</span>{" "}
                            <span className="text-[#8b949e]">
                              [native.refs]
                            </span>{" "}
                            <span className="text-[#c9d1d9]">
                              start
                              headRefOrigin/cmux/add-mock-example-to-preview-front-page
                            </span>
                          </div>
                          <div>
                            <span className="text-[#f0883e]">[SERVER]</span>{" "}
                            <span className="text-[#8b949e]">
                              [native.refs]
                            </span>{" "}
                            <span className="text-[#c9d1d9]">
                              adfasdfadfa...asdfasdfasdfadsf
                            </span>
                          </div>
                          <div>
                            <span className="text-[#58a6ff]">[WWW]</span>{" "}
                            <span className="text-[#c9d1d9]">
                              Request url:
                              http://localhost:9779/api/iframe/preflight
                            </span>
                          </div>
                          <div>
                            <span className="text-[#58a6ff]">[WWW]</span>{" "}
                            <span className="text-[#7ee787]">--&gt;</span>{" "}
                            <span className="text-[#c9d1d9]">
                              OPTIONS /api/iframe/preflight
                            </span>{" "}
                            <span className="text-[#7ee787]">204</span>{" "}
                            <span className="text-[#8b949e]">0ms</span>
                          </div>
                          <div>
                            <span className="text-[#58a6ff]">[WWW]</span>{" "}
                            <span className="text-[#7ee787]">--&gt;</span>{" "}
                            <span className="text-[#c9d1d9]">
                              GET /api/iframe/preflight
                            </span>{" "}
                            <span className="text-[#7ee787]">200</span>{" "}
                            <span className="text-[#8b949e]">in 41ms</span>
                          </div>
                          <div>
                            <span className="text-[#58a6ff]">[WWW]</span>{" "}
                            <span className="text-[#7ee787]">--&gt;</span>{" "}
                            <span className="text-[#c9d1d9]">
                              GET /api/iframe/preflight?url=...morphvn
                            </span>{" "}
                            <span className="text-[#7ee787]">200</span>{" "}
                            <span className="text-[#8b949e]">in 720ms</span>
                          </div>
                          <div className="mt-1" />
                          <div>
                            <span className="text-[#a371f7]">[CONVEX-DEV]</span>{" "}
                            <span className="text-[#8b949e]">
                              12/5/2025, 9:30:48 AM
                            </span>{" "}
                            <span className="text-[#c9d1d9]">
                              [LOG] &apos;preview-jobs-http&apos; Completing
                              preview job
                            </span>
                          </div>
                          <div>
                            <span className="text-[#a371f7]">[CONVEX-DEV]</span>{" "}
                            <span className="text-[#c9d1d9]">
                              {" "}
                              taskRunId:
                              &apos;adfasdfasdfasdfasdfasdfasdfasdfasdfasdf&apos;,
                            </span>
                          </div>
                          <div>
                            <span className="text-[#a371f7]">[CONVEX-DEV]</span>{" "}
                            <span className="text-[#c9d1d9]">
                              {" "}
                              previewRunId:
                              &apos;adsfsadfasdfasdfasdfasdf&apos;,
                            </span>
                          </div>
                          <div>
                            <span className="text-[#a371f7]">[CONVEX-DEV]</span>{" "}
                            <span className="text-[#c9d1d9]">
                              {" "}
                              imageCount: 8
                            </span>
                          </div>
                          <div className="mt-1" />
                          <div>
                            <span className="text-[#a371f7]">[CONVEX-DEV]</span>{" "}
                            <span className="text-[#8b949e]">
                              12/5/2025, 9:30:51 AM
                            </span>{" "}
                            <span className="text-[#7ee787]">
                              [LOG] Successfully posted preview comment
                            </span>
                          </div>
                          <div>
                            <span className="text-[#a371f7]">[CONVEX-DEV]</span>{" "}
                            <span className="text-[#c9d1d9]">
                              {" "}
                              prNumber: 1173,
                            </span>
                          </div>
                          <div>
                            <span className="text-[#a371f7]">[CONVEX-DEV]</span>{" "}
                            <span className="text-[#c9d1d9]">
                              {" "}
                              commentId: 3616083966,
                            </span>
                          </div>
                          <div className="mt-1" />
                          <div>
                            <span className="text-[#79c0ff]">[CLIENT]</span>{" "}
                            <span className="text-[#8b949e]">9:33:46 AM</span>{" "}
                            <span className="text-[#c9d1d9]">
                              [vite] (client) hmr update /src/index.css
                            </span>
                          </div>
                          <div>
                            <span className="text-[#79c0ff]">[CLIENT]</span>{" "}
                            <span className="text-[#8b949e]">9:34:28 AM</span>{" "}
                            <span className="text-[#c9d1d9]">
                              [vite] (client) hmr update
                              /src/components/TaskTree.tsx
                            </span>
                          </div>
                          {isPRMerged && (
                            <>
                              <div className="mt-1" />
                              <div>
                                <span className="text-[#a371f7]">
                                  [CONVEX-DEV]
                                </span>{" "}
                                <span className="text-[#8b949e]">
                                  12/5/2025, 9:40:44 AM
                                </span>{" "}
                                <span className="text-[#c9d1d9]">
                                  [LOG] &apos;PR merge handler&apos; Processing
                                  PR event
                                </span>
                              </div>
                              <div>
                                <span className="text-[#a371f7]">
                                  [CONVEX-DEV]
                                </span>{" "}
                                <span className="text-[#c9d1d9]">
                                  {" "}
                                  prNumber: 1168, isMerged: true, action:
                                  &apos;closed&apos;
                                </span>
                              </div>
                              <div>
                                <span className="text-[#a371f7]">
                                  [CONVEX-DEV]
                                </span>{" "}
                                <span className="text-[#c9d1d9]">
                                  {" "}
                                  Manaflow is always looking for the very best
                                  engineering talent. Please
                                  austin[at]manaflow.com to find the perfect
                                  fit.{" "}
                                </span>
                              </div>
                            </>
                          )}
                        </>
                      )}
                    </div>
                  </div>
                  {/* tmux status bar */}
                  <div className="flex items-center justify-between px-1 py-0.5 bg-[#238636] text-white text-[11px] shrink-0">
                    <div className="flex items-center">
                      <span className="text-[#7ee787] font-medium px-2">
                        [cmux]
                      </span>
                      {[
                        { id: 0, name: "bunx" },
                        { id: 1, name: "maintenance" },
                        { id: 2, name: "dev" },
                      ].map((session) => (
                        <button
                          key={session.id}
                          onClick={() => setActiveTmuxSession(session.id)}
                          className={clsx(
                            "px-2 py-0.5 transition-colors",
                            activeTmuxSession === session.id
                              ? "bg-[#2ea043] text-white font-medium"
                              : "hover:bg-[#2ea043]/50 text-white/90"
                          )}
                        >
                          {session.id}:{session.name}
                          {activeTmuxSession === session.id ? "*" : ""}
                        </button>
                      ))}
                    </div>
                    <div className="flex items-center gap-3 px-2">
                      <span className="text-white/90">09:41</span>
                      <span className="text-white/90">05-Dec-25</span>
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

/**
 * Shown in popup after GitHub App installation completes.
 * Sends message to opener and auto-closes after delay.
 */
function PopupCompleteView() {
  const [canClose, setCanClose] = useState(true);

  useEffect(() => {
    if (window.opener) {
      try {
        window.opener.postMessage(
          { type: "github_app_installed" },
          window.location.origin
        );
      } catch (error) {
        console.error("[PopupComplete] Failed to post message", error);
      }

      const timer = setTimeout(() => {
        try {
          window.close();
        } catch (error) {
          console.error("[PopupComplete] Failed to close popup", error);
          setCanClose(false);
        }
      }, 1500);

      return () => clearTimeout(timer);
    } else {
      window.location.href = "/preview";
    }
  }, []);

  return (
    <div className="min-h-dvh text-white flex items-center justify-center px-6">
      <div className="text-center max-w-md">
        <div className="mx-auto mb-6 grid place-items-center">
          <div className="h-14 w-14 rounded-full bg-emerald-500/10 ring-8 ring-emerald-500/5 grid place-items-center">
            <CheckCircle2 className="h-7 w-7 text-emerald-500" />
          </div>
        </div>
        <h1 className="text-2xl font-semibold">Installation Complete</h1>
        <p className="mt-2 text-sm text-neutral-400">
          {canClose
            ? "Closing this window..."
            : "You can close this window and return to the previous page."}
        </p>
        {!canClose && (
          <button
            type="button"
            onClick={() => window.close()}
            className="mt-6 inline-flex items-center justify-center gap-2 rounded-lg bg-white px-6 py-3 text-base font-medium text-black transition-colors hover:bg-neutral-200"
          >
            Close Window
          </button>
        )}
      </div>
    </div>
  );
}

/** Opens a centered popup window */
function openCenteredPopup(
  url: string,
  name: string,
  width: number,
  height: number
) {
  const screenLeft = window.screenLeft ?? window.screenX;
  const screenTop = window.screenTop ?? window.screenY;
  const screenWidth = window.innerWidth;
  const screenHeight = window.innerHeight;

  const left = screenLeft + (screenWidth - width) / 2;
  const top = screenTop + (screenHeight - height) / 2;

  const features = `width=${width},height=${height},left=${left},top=${top},resizable=yes,scrollbars=yes`;
  return window.open(url, name, features);
}

// Create a stable QueryClient instance for the preview dashboard
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: false,
    },
  },
});

export function PreviewDashboard(props: PreviewDashboardProps) {
  return (
    <QueryClientProvider client={queryClient}>
      <PreviewDashboardInner {...props} />
    </QueryClientProvider>
  );
}

function PreviewDashboardInner({
  selectedTeamSlugOrId,
  teamOptions,
  providerConnectionsByTeam,
  isAuthenticated,
  previewConfigs,
  popupComplete,
  waitlistProviders,
  waitlistEmail,
  paywall,
}: PreviewDashboardProps) {
  const [selectedTeamSlugOrIdState, setSelectedTeamSlugOrIdState] = useState(
    () => selectedTeamSlugOrId || teamOptions[0]?.slugOrId || ""
  );
  const [isInstallingApp, setIsInstallingApp] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [configError, setConfigError] = useState<string | null>(null);
  const [checkoutError, setCheckoutError] = useState<string | null>(null);
  const [openingCheckout, setOpeningCheckout] = useState(false);

  const stackUser = useUser({ or: "return-null" });

  // Repository selection state
  const [selectedInstallationId, setSelectedInstallationId] = useState<
    number | null
  >(null);
  const [repoSearch, setRepoSearch] = useState("");
  const [debouncedRepoSearch, setDebouncedRepoSearch] = useState("");
  const [navigatingRepo, setNavigatingRepo] = useState<string | null>(null);
  const [configs, setConfigs] =
    useState<PreviewConfigListItem[]>(previewConfigs);
  const [updatingConfigId, setUpdatingConfigId] = useState<string | null>(null);
  const [openingConfigId, setOpeningConfigId] = useState<string | null>(null);
  const [configPendingDelete, setConfigPendingDelete] =
    useState<PreviewConfigListItem | null>(null);

  // OAuth sign-in with popup
  const { signInWithPopup, signingInProvider } = useOAuthPopup();

  // Public URL input state (commented out: quick setup input is disabled)
  // const [repoUrlInput, setRepoUrlInput] = useState("");

  const currentProviderConnections = useMemo(
    () => providerConnectionsByTeam[selectedTeamSlugOrIdState] ?? [],
    [providerConnectionsByTeam, selectedTeamSlugOrIdState]
  );
  const activeConnections = useMemo(
    () =>
      currentProviderConnections.filter((connection) => connection.isActive),
    [currentProviderConnections]
  );
  const previousTeamRef = useRef(selectedTeamSlugOrIdState);
  const hasGithubAppInstallation = activeConnections.length > 0;
  const canSearchRepos =
    isAuthenticated &&
    Boolean(selectedTeamSlugOrIdState) &&
    hasGithubAppInstallation;

  // Debounce search input
  useEffect(() => {
    const timeoutId = setTimeout(() => {
      setDebouncedRepoSearch(repoSearch.trim());
    }, 300);
    return () => clearTimeout(timeoutId);
  }, [repoSearch]);

  // Fetch repos using TanStack Query
  const reposQuery = useQuery({
    queryKey: [
      "github-repos",
      selectedTeamSlugOrIdState,
      selectedInstallationId,
      debouncedRepoSearch,
    ],
    queryFn: async ({ signal }) => {
      const params = new URLSearchParams({
        team: selectedTeamSlugOrIdState,
        installationId: String(selectedInstallationId),
      });
      if (debouncedRepoSearch) {
        params.set("search", debouncedRepoSearch);
      }
      const response = await fetch(
        `/api/integrations/github/repos?${params.toString()}`,
        { signal }
      );
      if (!response.ok) {
        throw new Error(await response.text());
      }
      return response.json() as Promise<{ repos: RepoSearchResult[] }>;
    },
    enabled: canSearchRepos && selectedInstallationId !== null,
    staleTime: 30_000,
  });

  const repos: RepoSearchResult[] = useMemo(() => {
    if (!reposQuery.data?.repos) return [];
    // When no search, limit to 5 results
    return debouncedRepoSearch
      ? reposQuery.data.repos
      : reposQuery.data.repos.slice(0, 5);
  }, [reposQuery.data?.repos, debouncedRepoSearch]);

  const isLoadingRepos = reposQuery.isLoading || reposQuery.isFetching;

  useEffect(() => {
    setConfigs(previewConfigs);
  }, [previewConfigs]);

  // Parse GitHub URL to extract owner/repo (commented out: quick setup input is disabled)
  // const parseGithubUrl = useCallback((input: string): string | null => {
  //   const trimmed = input.trim();
  //   // Try to parse as URL
  //   try {
  //     const url = new URL(trimmed);
  //     if (url.hostname === "github.com" || url.hostname === "www.github.com") {
  //       const parts = url.pathname.split("/").filter(Boolean);
  //       if (parts.length >= 2) {
  //         return `${parts[0]}/${parts[1]}`;
  //       }
  //     }
  //   } catch {
  //     // Not a valid URL, check if it's owner/repo format
  //     const ownerRepoMatch = trimmed.match(
  //       /^([a-zA-Z0-9_.-]+)\/([a-zA-Z0-9_.-]+)$/
  //     );
  //     if (ownerRepoMatch) {
  //       return trimmed;
  //     }
  //   }
  //   return null;
  // }, []);

  const handleOpenConfig = useCallback((config: PreviewConfigListItem) => {
    setOpeningConfigId(config.id);
    const params = new URLSearchParams({
      repo: config.repoFullName,
      team: config.teamSlugOrId,
    });
    if (config.repoInstallationId !== null) {
      params.set("installationId", String(config.repoInstallationId));
    }
    if (config.environmentId) {
      params.set("environmentId", config.environmentId);
    }
    window.location.href = `/preview/configure?${params.toString()}`;
  }, []);

  const handleRequestDelete = useCallback((config: PreviewConfigListItem) => {
    setConfigError(null);
    setConfigPendingDelete(config);
  }, []);

  const handleDeleteConfig = useCallback(async () => {
    if (!configPendingDelete) return;
    setUpdatingConfigId(configPendingDelete.id);
    setConfigError(null);
    try {
      const params = new URLSearchParams({
        teamSlugOrId: configPendingDelete.teamSlugOrId,
      });
      const response = await fetch(
        `/api/preview/configs/${configPendingDelete.id}?${params.toString()}`,
        {
          method: "DELETE",
          headers: { "Content-Type": "application/json" },
        }
      );
      if (!response.ok) {
        throw new Error(await response.text());
      }
      setConfigs((previous) =>
        previous.filter((item) => item.id !== configPendingDelete.id)
      );
      setConfigPendingDelete(null);
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to delete preview configuration";
      console.error(
        "[PreviewDashboard] Failed to delete preview configuration",
        error
      );
      setConfigError(message);
    } finally {
      setUpdatingConfigId(null);
    }
  }, [configPendingDelete]);

  const handleCancelDelete = useCallback(() => {
    setConfigPendingDelete(null);
  }, []);

  const handleTeamChange = useCallback((nextTeam: string) => {
    setSelectedTeamSlugOrIdState(nextTeam);
    setSelectedInstallationId(null);
    setRepoSearch("");
    setErrorMessage(null);
  }, []);

  // handleStartPreview commented out: quick setup input is disabled
  // const handleStartPreview = useCallback(async () => {
  //   const repoName = parseGithubUrl(repoUrlInput);
  //   if (!repoName) {
  //     setErrorMessage("Please enter a valid GitHub URL or owner/repo");
  //     return;
  //   }
  //
  //   // For unauthenticated users, redirect to sign-in without requiring team selection
  //   if (!isAuthenticated) {
  //     const params = new URLSearchParams({ repo: repoName });
  //     // Include team if available, otherwise the configure page will handle it after sign-in
  //     if (selectedTeamSlugOrIdState) {
  //       params.set("team", selectedTeamSlugOrIdState);
  //     }
  //     const configurePath = `/preview/configure?${params.toString()}`;
  //     setErrorMessage(null);
  //     setNavigatingRepo("__url_input__");
  //     window.location.href = `/handler/sign-in?after_auth_return_to=${encodeURIComponent(configurePath)}`;
  //     return;
  //   }
  //
  //   if (!selectedTeamSlugOrIdState) {
  //     setErrorMessage("Select a team before continuing.");
  //     return;
  //   }
  //
  //   const params = new URLSearchParams({ repo: repoName });
  //   params.set("team", selectedTeamSlugOrIdState);
  //   const configurePath = `/preview/configure?${params.toString()}`;
  //
  //   if (!hasGithubAppInstallation) {
  //     setErrorMessage(null);
  //     setIsInstallingApp(true);
  //     setNavigatingRepo("__url_input__");
  //
  //     try {
  //       const response = await fetch("/api/integrations/github/install-state", {
  //         method: "POST",
  //         headers: { "Content-Type": "application/json" },
  //         body: JSON.stringify({
  //           teamSlugOrId: selectedTeamSlugOrIdState,
  //           returnUrl: new URL(
  //             configurePath,
  //             window.location.origin
  //           ).toString(),
  //         }),
  //       });
  //
  //       if (!response.ok) {
  //         throw new Error(await response.text());
  //       }
  //
  //       const payload = (await response.json()) as { state: string };
  //       const githubAppSlug = process.env.NEXT_PUBLIC_GITHUB_APP_SLUG;
  //       if (!githubAppSlug) {
  //         throw new Error("GitHub App slug is not configured");
  //       }
  //
  //       const url = new URL(
  //         `https://github.com/apps/${githubAppSlug}/installations/new`
  //       );
  //       url.searchParams.set("state", payload.state);
  //       window.location.href = url.toString();
  //       return;
  //     } catch (error) {
  //       const message =
  //         error instanceof Error
  //           ? error.message
  //           : "Failed to start GitHub App install";
  //       console.error(
  //         "[PreviewDashboard] Failed to start GitHub App install",
  //         error
  //       );
  //       setErrorMessage(message);
  //       setIsInstallingApp(false);
  //       setNavigatingRepo(null);
  //       return;
  //     }
  //   }
  //
  //   setErrorMessage(null);
  //   setNavigatingRepo("__url_input__");
  //   window.location.href = configurePath;
  // }, [
  //   repoUrlInput,
  //   parseGithubUrl,
  //   selectedTeamSlugOrIdState,
  //   hasGithubAppInstallation,
  //   isAuthenticated,
  // ]);

  // Auto-select first connection for the team, but keep user choice if still valid
  useEffect(() => {
    const fallbackInstallationId = activeConnections[0]?.installationId ?? null;
    const teamChanged = previousTeamRef.current !== selectedTeamSlugOrIdState;
    const hasSelectedConnection = activeConnections.some(
      (connection) => connection.installationId === selectedInstallationId
    );

    if (activeConnections.length === 0) {
      if (selectedInstallationId !== null) {
        setSelectedInstallationId(null);
      }
    } else if (teamChanged || !hasSelectedConnection) {
      if (selectedInstallationId !== fallbackInstallationId) {
        setSelectedInstallationId(fallbackInstallationId);
      }
    }

    previousTeamRef.current = selectedTeamSlugOrIdState;
  }, [activeConnections, selectedInstallationId, selectedTeamSlugOrIdState]);

  // Popup ref and listener for GitHub App installation
  const installPopupRef = useRef<Window | null>(null);

  // Listen for GitHub App installation completion
  useEffect(() => {
    const handleMessage = (event: MessageEvent) => {
      if (event.origin !== window.location.origin) return;
      if (event.data?.type === "github_app_installed") {
        setIsInstallingApp(false);
        // Reload to get the new installation
        window.location.reload();
      }
    };

    const handleFocus = () => {
      // Check if popup was closed when we regain focus
      if (installPopupRef.current && isInstallingApp) {
        setTimeout(() => {
          try {
            if (installPopupRef.current?.closed) {
              setIsInstallingApp(false);
              installPopupRef.current = null;
            }
          } catch {
            // Ignore cross-origin errors
          }
        }, 500);
      }
    };

    window.addEventListener("message", handleMessage);
    window.addEventListener("focus", handleFocus);

    return () => {
      window.removeEventListener("message", handleMessage);
      window.removeEventListener("focus", handleFocus);
    };
  }, [isInstallingApp]);

  const handleInstallGithubApp = async () => {
    if (!selectedTeamSlugOrIdState) {
      setErrorMessage("Select a team first");
      return;
    }

    setIsInstallingApp(true);
    setErrorMessage(null);
    try {
      // Use popup_complete query param as returnUrl so it can signal the parent window and close
      const popupCompleteUrl = new URL(
        "/preview?popup_complete=true",
        window.location.origin
      ).toString();

      const response = await fetch("/api/integrations/github/install-state", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId: selectedTeamSlugOrIdState,
          returnUrl: popupCompleteUrl,
        }),
      });
      if (!response.ok) {
        throw new Error(await response.text());
      }
      const payload = (await response.json()) as { installUrl: string };

      // Open centered popup for GitHub App installation
      const popup = openCenteredPopup(
        payload.installUrl,
        "github-app-install",
        1000,
        700
      );

      if (!popup) {
        // Popup was blocked - fall back to redirect
        console.warn(
          "[PreviewDashboard] Popup blocked, falling back to redirect"
        );
        window.location.href = payload.installUrl;
        return;
      }

      installPopupRef.current = popup;
      popup.focus();
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to start GitHub App install";
      console.error(
        "[PreviewDashboard] Failed to start GitHub App install",
        error
      );
      setErrorMessage(message);
      setIsInstallingApp(false);
    }
  };

  const handleContinue = useCallback(
    (repoName: string) => {
      if (!repoName.trim()) return;
      setNavigatingRepo(repoName);
      const params = new URLSearchParams({
        repo: repoName,
        installationId: String(selectedInstallationId ?? ""),
        team: selectedTeamSlugOrIdState,
      });
      window.location.href = `/preview/configure?${params.toString()}`;
    },
    [selectedInstallationId, selectedTeamSlugOrIdState]
  );

  useEffect(() => {
    if (!selectedTeamSlugOrIdState && teamOptions[0]) {
      setSelectedTeamSlugOrIdState(teamOptions[0].slugOrId);
    }
  }, [selectedTeamSlugOrIdState, teamOptions]);

  // Repo selection box - only this part, not configured repos
  const repoSelectionBox = !isAuthenticated ? (
    <div className="relative flex flex-1 flex-col items-center justify-center rounded-lg border border-white/5 bg-white/[0.02] backdrop-blur-sm px-4 py-10 overflow-hidden">
      <GrainOverlay opacity={0.02} />
      <p className="text-sm text-neutral-300/85 pb-6 max-w-xs text-center">
        Select a Git provider to import a Git Repository
      </p>
      <div className="flex flex-col gap-3 w-full max-w-xs">
        <Button
          onClick={() => signInWithPopup("github")}
          disabled={signingInProvider !== null}
          className="w-full h-10 bg-[#24292f] text-white hover:bg-[#32383f] inline-flex items-center justify-center gap-2 disabled:opacity-50"
        >
          {signingInProvider === "github" ? (
            <Loader2 className="h-[18px] w-[18px] animate-spin" />
          ) : (
            <svg
              className="h-[18px] w-[18px] shrink-0"
              viewBox="0 0 24 24"
              fill="currentColor"
            >
              <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z" />
            </svg>
          )}
          Continue with GitHub
        </Button>
        <Button
          onClick={() => signInWithPopup("gitlab")}
          disabled={signingInProvider !== null}
          className="w-full h-10 bg-[#fc6d26] text-white hover:bg-[#ff8245] inline-flex items-center justify-center gap-2 disabled:opacity-50"
        >
          {signingInProvider === "gitlab" ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <svg
              className="h-4 w-4 shrink-0"
              viewBox="90 90 200 175"
              fill="currentColor"
            >
              <path d="M282.83,170.73l-.27-.69-26.14-68.22a6.81,6.81,0,0,0-2.69-3.24,7,7,0,0,0-8,.43,7,7,0,0,0-2.32,3.52l-17.65,54H154.29l-17.65-54A6.86,6.86,0,0,0,134.32,99a7,7,0,0,0-8-.43,6.87,6.87,0,0,0-2.69,3.24L97.44,170l-.26.69a48.54,48.54,0,0,0,16.1,56.1l.09.07.24.17,39.82,29.82,19.7,14.91,12,9.06a8.07,8.07,0,0,0,9.76,0l12-9.06,19.7-14.91,40.06-30,.1-.08A48.56,48.56,0,0,0,282.83,170.73Z" />
            </svg>
          )}
          Continue with GitLab
        </Button>
        <Button
          onClick={() => signInWithPopup("bitbucket")}
          disabled={signingInProvider !== null}
          className="w-full h-10 bg-[#0052cc] text-white hover:bg-[#006cf2] inline-flex items-center justify-center gap-2 disabled:opacity-50"
        >
          {signingInProvider === "bitbucket" ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <svg className="h-4 w-4 shrink-0" viewBox="-2 -2 65 59">
              <defs>
                <linearGradient
                  id="bitbucket-grad"
                  x1="104.953%"
                  x2="46.569%"
                  y1="21.921%"
                  y2="75.234%"
                >
                  <stop
                    offset="7%"
                    stopColor="currentColor"
                    stopOpacity="0.4"
                  />
                  <stop offset="100%" stopColor="currentColor" />
                </linearGradient>
              </defs>
              <path
                d="M59.696 18.86h-18.77l-3.15 18.39h-13L9.426 55.47a2.71 2.71 0 001.75.66h40.74a2 2 0 002-1.68l5.78-35.59z"
                fill="url(#bitbucket-grad)"
                fillRule="nonzero"
                transform="translate(-.026 .82)"
              />
              <path
                d="M2 .82a2 2 0 00-2 2.32l8.49 51.54a2.7 2.7 0 00.91 1.61 2.71 2.71 0 001.75.66l15.76-18.88H24.7l-3.47-18.39h38.44l2.7-16.53a2 2 0 00-2-2.32L2 .82z"
                fill="currentColor"
                fillRule="nonzero"
              />
            </svg>
          )}
          Continue with Bitbucket
        </Button>
      </div>
    </div>
  ) : waitlistProviders && waitlistProviders.length > 0 ? (
    // Waitlist for GitLab/Bitbucket users who don't have GitHub connected
    (() => {
      const providerNames = waitlistProviders.map((p) =>
        p === "gitlab" ? "GitLab" : "Bitbucket"
      );
      const providerDisplay =
        providerNames.length === 1
          ? providerNames[0]
          : `${providerNames.slice(0, -1).join(", ")} and ${providerNames[providerNames.length - 1]}`;
      return (
        <div className="relative flex flex-1 flex-col items-center justify-center rounded-lg border border-white/5 bg-white/[0.02] backdrop-blur-sm px-4 py-8 overflow-hidden">
          <GrainOverlay opacity={0.02} />
          <h3 className="text-base font-medium text-white mb-2">
            You&apos;re on the waitlist!
          </h3>
          <div className="text-sm text-neutral-400 text-center max-w-md space-y-2">
            <p>
              {providerDisplay} integration is in beta. We&apos;ll email you
              when it&apos;s ready.
            </p>
            {waitlistEmail && (
              <p className="text-neutral-500 text-xs">({waitlistEmail})</p>
            )}
          </div>
          <p className="text-xs text-neutral-500 mt-4 text-center">
            In the meantime, you can use Preview with GitHub.
          </p>
          <Suspense fallback={<div className="h-[36px] mt-4" />}>
            <UseDifferentAccountButton />
          </Suspense>
        </div>
      );
    })()
  ) : !hasGithubAppInstallation ? (
    <div className="relative flex flex-1 flex-col items-center justify-center rounded-lg border border-white/5 bg-white/[0.02] backdrop-blur-sm overflow-hidden py-16 sm:py-10">
      <GrainOverlay opacity={0.02} />
      <h3 className="text-base font-medium text-white pb-5">
        No connected repositories
      </h3>
      <Button
        onClick={handleInstallGithubApp}
        disabled={isInstallingApp}
        className="inline-flex items-center gap-2 bg-white text-black hover:bg-neutral-200"
      >
        {isInstallingApp ? (
          <Loader2 className="h-4 w-4 animate-spin" />
        ) : (
          <svg className="h-4 w-4" viewBox="0 0 24 24" fill="currentColor">
            <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z" />
          </svg>
        )}
        Add repositories
      </Button>
      {errorMessage && (
        <p className="pt-4 text-sm text-red-400">{errorMessage}</p>
      )}
    </div>
  ) : (
    <div className="flex flex-1 flex-col overflow-hidden rounded-lg border border-white/10">
      <div className="flex border-b border-white/10 shrink-0">
        <div className="relative border-r border-white/10">
          {isInstallingApp ? (
            <Loader2 className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 h-4 w-4 animate-spin text-white" />
          ) : (
            <svg
              className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 h-4 w-4"
              viewBox="0 0 24 24"
              fill="white"
            >
              <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z" />
            </svg>
          )}
          <select
            value={selectedInstallationId ?? ""}
            onChange={(e) => {
              const value = e.target.value;
              if (value === ADD_INSTALLATION_VALUE) {
                void handleInstallGithubApp();
                return;
              }
              setSelectedInstallationId(Number(value));
            }}
            disabled={isInstallingApp}
            className="h-10 appearance-none bg-transparent py-2 pl-11 pr-8 text-sm text-white focus:outline-none disabled:cursor-not-allowed disabled:opacity-50"
          >
            {activeConnections.map((conn) => (
              <option key={conn.id} value={conn.installationId}>
                {conn.accountLogin || `ID: ${conn.installationId}`}
              </option>
            ))}
            <option value={ADD_INSTALLATION_VALUE}>Add account</option>
          </select>
          <div className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2">
            <svg
              className="h-4 w-4 text-neutral-500"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M19 9l-7 7-7-7"
              />
            </svg>
          </div>
        </div>

        <div className="relative flex-1">
          <Search className="absolute left-4 top-1/2 -translate-y-1/2 h-4 w-4 text-neutral-500" />
          <input
            type="text"
            value={repoSearch}
            onChange={(e) => setRepoSearch(e.target.value)}
            placeholder="Search..."
            disabled={!canSearchRepos}
            className="h-10 w-full bg-transparent py-2 pl-11 pr-4 text-sm text-white placeholder:text-neutral-500 focus:outline-none disabled:cursor-not-allowed disabled:opacity-50"
          />
        </div>
      </div>

      <div
        className="flex-1 divide-y divide-white/5"
        style={{
          scrollbarWidth: "thin",
          scrollbarColor: "rgba(255,255,255,0.2) transparent",
        }}
      >
        {!canSearchRepos ? (
          <div className="flex items-center justify-center h-full text-sm text-neutral-500">
            Select a team and install the GitHub App to search.
          </div>
        ) : isLoadingRepos ? (
          <div className="flex items-center justify-center h-full min-h-[225px]">
            <Loader2 className="h-5 w-5 animate-spin text-neutral-500" />
          </div>
        ) : repos.length > 0 ? (
          repos.slice(0, 5).map((repo) => (
            <div
              key={repo.full_name}
              className="flex items-center justify-between px-4 py-2.5"
            >
              <div className="flex items-center gap-2.5 min-w-0">
                <svg
                  className="h-4 w-4 shrink-0"
                  viewBox="0 0 24 24"
                  fill="white"
                >
                  <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z" />
                </svg>
                <span className="text-sm text-white truncate">
                  {repo.full_name}
                </span>
              </div>
              <Button
                onClick={() => handleContinue(repo.full_name)}
                disabled={navigatingRepo !== null || !selectedInstallationId}
                size="sm"
                className="h-6 px-3 text-xs bg-white text-black hover:bg-neutral-200 min-w-[55px] cursor-pointer"
              >
                {navigatingRepo === repo.full_name ? (
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                ) : (
                  "Import"
                )}
              </Button>
            </div>
          ))
        ) : (
          <div className="flex flex-col items-center justify-center h-full text-sm text-neutral-500">
            <p>No repositories found</p>
          </div>
        )}
      </div>
    </div>
  );

  // Render popup complete UI if in popup mode
  if (popupComplete) {
    return <PopupCompleteView />;
  }

  return (
    <div className="w-full max-w-5xl px-6 py-10 font-sans">
      {/* Header */}
      <div className="pb-10">
        <h1 className="text-3xl font-semibold tracking-tight text-white pb-2">
          Screenshot previews for GitHub PRs
        </h1>
        <p className="text-lg text-neutral-300/85 max-w-2xl">
          Code review agent that takes screenshots of code diffs involving UI
          changes
        </p>
      </div>

      {paywall?.isBlocked && (
        <div className="rounded-xl border border-white/10 bg-white/[0.02] backdrop-blur-sm p-4 mb-10">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="min-w-0">
              <p className="text-sm font-medium text-white">
                Free limit reached
              </p>
              <p className="text-sm text-neutral-300/85">
                You&apos;ve used {paywall.usedRuns} of {paywall.freeLimit} free
                PR previews. Upgrade to unlock previews for new pull requests.
              </p>
            </div>
            <div className="flex items-center gap-2">
              <Button
                disabled={!stackUser || openingCheckout}
                onClick={() => {
                  if (!stackUser) return;
                  if (!paywall.productId) return;
                  setCheckoutError(null);
                  setOpeningCheckout(true);
                  void (async () => {
                    try {
                      // Use team-level checkout via API route
                      const response = await fetch("/api/preview/checkout", {
                        method: "POST",
                        headers: { "Content-Type": "application/json" },
                        body: JSON.stringify({
                          productId: paywall.productId,
                          teamSlugOrId: selectedTeamSlugOrIdState,
                        }),
                      });
                      if (!response.ok) {
                        const text = await response.text();
                        throw new Error(text || "Failed to create checkout session");
                      }
                      const { checkoutUrl } = await response.json();
                      window.location.href = checkoutUrl;
                    } catch (error) {
                      console.error(
                        "[PreviewDashboard] Failed to create checkout URL",
                        error
                      );
                      setCheckoutError(
                        error instanceof Error
                          ? error.message
                          : "Failed to start checkout"
                      );
                    } finally {
                      setOpeningCheckout(false);
                    }
                  })();
                }}
                className="h-9 px-4 bg-white text-black hover:bg-neutral-200"
              >
                {openingCheckout ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  "Upgrade"
                )}
              </Button>
              <Link
                href={`/preview/subscription?team=${encodeURIComponent(
                  selectedTeamSlugOrIdState
                )}`}
                className="inline-flex items-center justify-center h-9 px-4 rounded-md border border-white/10 bg-white/5 text-sm text-white hover:bg-white/10"
              >
                View plans
              </Link>
            </div>
          </div>
          {checkoutError && (
            <p className="text-xs text-red-400 pt-2">{checkoutError}</p>
          )}
        </div>
      )}

      {/* Quick Setup Input */}
      {/* <div id="setup-preview" className="pb-10">
        <div className="flex rounded-lg border border-white/10 overflow-hidden">
          <div className="relative flex-1 flex items-center bg-white/5 backdrop-blur-sm">
            <Link2 className="absolute left-4 h-5 w-5 text-neutral-500 z-10" />
            <input
              type="text"
              value={repoUrlInput}
              onChange={(e) => setRepoUrlInput(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && void handleStartPreview()}
              placeholder="Enter a Git repository URL to setup screenshot previews..."
              className="w-full h-10 bg-transparent pl-11 pr-4 text-sm text-white placeholder:text-neutral-500 focus:outline-none"
            />
          </div>
          <Button
            onClick={() => void handleStartPreview()}
            disabled={
              !repoUrlInput.trim() ||
              navigatingRepo !== null ||
              (isAuthenticated && !selectedTeamSlugOrIdState)
            }
            className="h-10 px-4 rounded-none bg-white/90 backdrop-blur-sm text-black hover:bg-white text-sm font-medium"
          >
            {navigatingRepo === "__url_input__" ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              "Continue"
            )}
          </Button>
        </div>
        {errorMessage && (
          <p className="text-xs text-red-400 pt-2">{errorMessage}</p>
        )}
      </div> */}

      {/* Main content grid */}
      <div className="grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        {/* Left Column: Choose a repository */}
        <Section
          title="Choose a repository"
          headerContent={
            isAuthenticated && teamOptions.length > 0 ? (
              <div className="flex items-center gap-2.5">
                <label className="text-sm text-neutral-500">Team</label>
                <div className="relative">
                  <select
                    value={selectedTeamSlugOrIdState}
                    onChange={(e) => handleTeamChange(e.target.value)}
                    className="appearance-none rounded-md border border-white/10 bg-white/5 pl-3 pr-8 py-1.5 text-sm text-white focus:border-white/20 focus:outline-none"
                  >
                    {teamOptions.map((team) => (
                      <option key={team.slugOrId} value={team.slugOrId}>
                        {team.displayName}
                      </option>
                    ))}
                  </select>
                  <div className="pointer-events-none absolute right-2.5 top-2">
                    <svg
                      className="h-4 w-4 text-neutral-500"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        strokeWidth={2}
                        d="M19 9l-7 7-7-7"
                      />
                    </svg>
                  </div>
                </div>
              </div>
            ) : undefined
          }
        >
          {repoSelectionBox}
        </Section>

        {/* Right Column: What is preview.new? */}
        <Section title="What is preview.new?">
          <div className="space-y-3">
            <FeatureCard
              icon={Camera}
              iconBgColor="bg-sky-500/10"
              iconColor="text-sky-400"
              title="Computer use agent"
              description="An agent boots your dev server and captures screenshots of your UI on every PR."
            />
            <FeatureCard
              icon={Github}
              iconBgColor="bg-emerald-500/10"
              iconColor="text-emerald-400"
              title="GitHub comments"
              description="Screenshots are posted directly to your PR as comments for easy review."
            />
            <FeatureCard
              icon={Server}
              iconBgColor="bg-purple-500/10"
              iconColor="text-purple-400"
              title="Isolated dev servers"
              description="Each PR runs in a dedicated VM with your exact dev environment."
            />
          </div>
        </Section>

        {/* Configured repositories and From creators */}
        <div className="pt-4 lg:col-span-2 grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
          {/* Left: Configured repositories */}
          <Section
            title="Configured repositories"
            headerContent={
              configError ? (
                <span className="text-sm text-red-400">{configError}</span>
              ) : undefined
            }
          >
            {configs.length === 0 ? (
              <p className="text-sm text-neutral-400">
                No preview configs yet.{" "}
                {isAuthenticated && hasGithubAppInstallation
                  ? "Choose a repository above to create one."
                  : "Connect GitHub and import a repository to get started."}
              </p>
            ) : (
              <TooltipProvider>
                <div className="space-y-1.5">
                  {configs.map((config) => (
                    <div
                      key={config.id}
                      className="flex items-center justify-between pl-0 pr-3 py-1"
                    >
                      <div className="flex items-center gap-2.5 min-w-0">
                        <svg
                          className="h-4 w-4 shrink-0"
                          viewBox="0 0 24 24"
                          fill="white"
                        >
                          <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z" />
                        </svg>
                        <span className="text-sm text-white truncate">
                          {config.repoFullName}
                        </span>
                        <div className="flex items-center gap-2.5 translate-y-[0.5px]">
                          <span className="text-xs text-neutral-600">
                            {config.teamName}
                          </span>
                          <span
                            className={clsx(
                              "text-xs px-2 py-0.5 rounded",
                              config.status === "active"
                                ? "bg-emerald-500/10 text-emerald-400"
                                : config.status === "paused"
                                  ? "bg-amber-500/10 text-amber-400"
                                  : "bg-neutral-500/10 text-neutral-400"
                            )}
                          >
                            {config.status}
                          </span>
                        </div>
                      </div>
                      <div className="flex items-center gap-1.5">
                        <Tooltip>
                          <TooltipTrigger asChild delayDuration={0}>
                            <button
                              type="button"
                              onClick={() => handleOpenConfig(config)}
                              disabled={openingConfigId === config.id}
                              className="p-1.5 text-neutral-500 disabled:opacity-50"
                            >
                              {openingConfigId === config.id ? (
                                <Loader2 className="h-4 w-4 animate-spin" />
                              ) : (
                                <Pencil className="h-4 w-4" />
                              )}
                            </button>
                          </TooltipTrigger>
                          <TooltipContent side="top" className="text-xs">
                            Edit configuration
                          </TooltipContent>
                        </Tooltip>
                        <Tooltip>
                          <TooltipTrigger asChild delayDuration={0}>
                            <button
                              type="button"
                              onClick={() => handleRequestDelete(config)}
                              disabled={updatingConfigId === config.id}
                              className="p-1.5 text-red-400 disabled:opacity-50"
                            >
                              {updatingConfigId === config.id ? (
                                <Loader2 className="h-4 w-4 animate-spin" />
                              ) : (
                                <Trash2 className="h-4 w-4" />
                              )}
                            </button>
                          </TooltipTrigger>
                          <TooltipContent side="top" className="text-xs">
                            Delete configuration
                          </TooltipContent>
                        </Tooltip>
                      </div>
                    </div>
                  ))}
                </div>
              </TooltipProvider>
            )}
          </Section>

          {/* Right: From creators section */}
          <Section
            title="From the creators of"
            inlineHeader={true}
            headerContent={
              <Link
                href="https://cmux.dev"
                className="inline-flex items-center hover:opacity-80 transition-opacity"
                style={{ transform: "translate(-2.5px, -0.5px)" }}
              >
                <CmuxLogo
                  height="2em"
                  wordmarkText="cmux.dev"
                  wordmarkFill="#fff"
                />
              </Link>
            }
          >
            <p className="text-sm text-neutral-400 pb-2">
              Want UI screenshots for your code reviews? Check out cmux - an
              open-source Claude Code/Codex manager with visual diffs!
            </p>
            <div className="flex items-center gap-3 pt-2">
              <Link
                href="https://github.com/manaflow-ai/cmux"
                className="inline-flex items-center gap-1.5 rounded-md border border-white/10 bg-white/5 px-3 py-1.5 text-xs text-white"
              >
                <Star className="h-3.5 w-3.5" />
                Star on GitHub
              </Link>
              <Link
                href="https://cmux.dev"
                className="inline-flex items-center gap-1.5 rounded-md border border-white/10 bg-white/5 px-3 py-1.5 text-xs text-white"
              >
                <ExternalLink className="h-3.5 w-3.5" />
                Explore cmux
              </Link>
            </div>
          </Section>
        </div>
      </div>

      {/* Mock GitHub PR browser demo */}
      <MockGitHubPRBrowser />

      <AlertDialog
        open={configPendingDelete !== null}
        onOpenChange={(open) => {
          if (!open && updatingConfigId !== configPendingDelete?.id) {
            handleCancelDelete();
          }
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <div className="rounded-full bg-red-500/10 p-2 text-red-400">
              <Trash2 className="h-5 w-5" />
            </div>
            <div className="flex-1">
              <AlertDialogTitle>Delete configuration?</AlertDialogTitle>
              <AlertDialogDescription>
                Are you sure you want to remove{" "}
                <span className="text-white">
                  {configPendingDelete?.repoFullName}
                </span>{" "}
                from preview.new? This stops screenshot previews for this
                repository.
              </AlertDialogDescription>
            </div>
          </AlertDialogHeader>
          {configError && (
            <p className="pt-3 text-sm text-red-400">{configError}</p>
          )}
          <AlertDialogFooter>
            <AlertDialogCancel asChild>
              <Button
                disabled={updatingConfigId === configPendingDelete?.id}
                variant="secondary"
              >
                Cancel
              </Button>
            </AlertDialogCancel>
            <AlertDialogAction asChild>
              <Button
                onClick={() => void handleDeleteConfig()}
                disabled={updatingConfigId === configPendingDelete?.id}
                variant="destructive"
              >
                {updatingConfigId === configPendingDelete?.id ? (
                  <Loader2 className="pr-2 h-4 w-4 animate-spin" />
                ) : (
                  "Delete"
                )}
              </Button>
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
