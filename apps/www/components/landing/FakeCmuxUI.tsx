"use client";

import {
  useEffect,
  useMemo,
  memo,
  useRef,
  useState,
  type ComponentType,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
} from "react";
import clsx from "clsx";
import CmuxLogo from "@/components/logo/cmux-logo";
import { VSCodeIcon } from "@/components/icons/vscode-icon";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { AGENT_CONFIGS, type AgentConfigApiKey } from "@cmux/shared/agentConfig";
import { API_KEY_MODELS_BY_ENV } from "@cmux/shared/model-usage";
import {
  AlertCircle,
  ArrowLeft,
  ArrowRight,
  Calendar,
  Check,
  CheckCircle,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Circle,
  Cloud,
  Command,
  Copy,
  Eye,
  EyeOff,
  GitBranch,
  GitCompare,
  GitMerge,
  GitPullRequest,
  GitPullRequestDraft,
  HardDrive,
  HelpCircle,
  Home,
  Image as ImageIcon,
  Link2,
  Mic,
  Minus,
  Plus,
  Play,
  RefreshCw,
  Server,
  Settings,
  X,
  XCircle,
} from "lucide-react";

// Drag bounds - defined outside component to avoid dependency issues
const BOUNDS = { minX: -200, maxX: 200, minY: -50, maxY: 100 };

export type FakeCmuxUIVariant =
  | "dashboard"
  | "tasks"
  | "diff"
  | "vscode"
  | "pr"
  | "environments"
  | "settings";

type TaskStatus = "complete" | "running" | "pending";

type SidebarRunChildType = "vscode" | "diff";

type SidebarRunChild = {
  type: SidebarRunChildType;
  label: string;
};

type SidebarRun = {
  name: string;
  status: TaskStatus;
  children?: SidebarRunChild[];
};

type SidebarTask = {
  title: string;
  status: TaskStatus;
  expanded?: boolean;
  runs?: SidebarRun[];
};

type TaskRowStatus = "ready" | "running" | "blocked" | "success";

type TaskRow = {
  title: string;
  repo: string;
  time: string;
  status: TaskRowStatus;
};

type TaskCategory = {
  title: string;
  items: TaskRow[];
};

type EnvironmentCard = {
  name: string;
  description?: string;
  selectedRepos: string[];
  createdAt: string;
  snapshotId: string;
};

type EnvironmentFlowStep = "list" | "select" | "configure" | "workspace";

type EnvironmentRepoOption = {
  fullName: string;
  updated: string;
};

type EnvironmentEnvVar = {
  name: string;
  value: string;
  isSecret: boolean;
};

type PullRequestStatus = "open" | "merged" | "draft";

type PullRequestRow = {
  title: string;
  repo: string;
  status: PullRequestStatus;
};

type NavKey = "home" | "environments" | "settings";

type NavItem = {
  key: NavKey;
  label: string;
  icon: ComponentType<{ className?: string; "aria-hidden"?: boolean }>;
};

type FakeSelectOption = {
  value: string;
  label: string;
  icon?: ReactNode;
  iconKey?: string;
  heading?: boolean;
  disabled?: boolean;
};

export type FakeCmuxUIProps = {
  variant?: FakeCmuxUIVariant;
  draggable?: boolean;
  showDragHint?: boolean;
  className?: string;
};

const navItems: NavItem[] = [
  { key: "home", label: "Home", icon: Home },
  { key: "environments", label: "Environments", icon: Server },
  { key: "settings", label: "Settings", icon: Settings },
];

const pullRequests: PullRequestRow[] = [
  { title: "Devbox", repo: "cmux/devbox-v1", status: "open" },
  { title: "chore: daily morph snapshot...", repo: "morph-snapshot-20260120-...", status: "open" },
  { title: "chore: daily morph snapshot...", repo: "morph-snapshot-20260119-...", status: "open" },
  { title: "Add iOS app with Stack Au...", repo: "swift-ios-clean", status: "draft" },
  { title: "chore: daily morph snapshot...", repo: "morph-snapshot-20260118-...", status: "merged" },
];

const environments: EnvironmentCard[] = [
  {
    name: "Devbox",
    description: "Base environment with the agent CLI stack preinstalled.",
    selectedRepos: ["cmux/devbox-v1", "cmux/infra", "cmux/desktop-app"],
    createdAt: "2 hours ago",
    snapshotId: "morphvm_q11mhv3p",
  },
  {
    name: "Desktop app",
    description: "Electron + Swift toolchain for the desktop client.",
    selectedRepos: ["cmux/desktop-app", "cmux/launcher"],
    createdAt: "1 day ago",
    snapshotId: "morphvm_z82wq8a1",
  },
  {
    name: "Infra tools",
    description: "Terraform + monitoring agents preconfigured.",
    selectedRepos: ["cmux/infra"],
    createdAt: "3 days ago",
    snapshotId: "morphvm_h13jk0p8",
  },
];

const environmentRepoOptions: EnvironmentRepoOption[] = [
  { fullName: "cmux/devbox-v1", updated: "2h ago" },
  { fullName: "cmux/desktop-app", updated: "6h ago" },
  { fullName: "cmux/infra", updated: "Yesterday" },
  { fullName: "cmux/launcher", updated: "3d ago" },
  { fullName: "cmux/marketing", updated: "5d ago" },
];

const environmentMachinePresets = [
  {
    id: "4vcpu_16gb_48gb",
    label: "Standard",
    cpu: "4 vCPU",
    memory: "16GB RAM",
    disk: "48GB Disk",
    description: "Balanced default for most tasks.",
  },
  {
    id: "8vcpu_32gb_48gb",
    label: "Performance",
    cpu: "8 vCPU",
    memory: "32GB RAM",
    disk: "48GB Disk",
    description: "Faster builds and large repo workflows.",
  },
];

const MASKED_ENV_VALUE = "••••••••••••••••••••";

const PROVIDER_INFO: Record<string, { url?: string; helpText?: string }> = {
  CLAUDE_CODE_OAUTH_TOKEN: {
    helpText:
      "Run `claude setup-token` in your terminal and paste the output here. Preferred over API key.",
  },
  ANTHROPIC_API_KEY: {
    url: "https://console.anthropic.com/settings/keys",
  },
  OPENAI_API_KEY: {
    url: "https://platform.openai.com/api-keys",
  },
  CODEX_AUTH_JSON: {
    helpText:
      "Paste the contents of ~/.codex/auth.json here. This allows Codex to use your OpenAI authentication.",
  },
  OPENROUTER_API_KEY: {
    url: "https://openrouter.ai/keys",
  },
  GEMINI_API_KEY: {
    url: "https://console.cloud.google.com/apis/credentials",
  },
  MODEL_STUDIO_API_KEY: {
    url: "https://modelstudio.console.alibabacloud.com/?tab=playground#/api-key",
  },
  AMP_API_KEY: {
    url: "https://ampcode.com/settings",
  },
  CURSOR_API_KEY: {
    url: "https://cursor.com/dashboard?tab=integrations",
  },
  XAI_API_KEY: {
    url: "https://console.x.ai/",
  },
};

const MOCK_API_KEYS: AgentConfigApiKey[] = Array.from(
  new Map(
    AGENT_CONFIGS.flatMap((config) => config.apiKeys ?? []).map((key) => [
      key.envVar,
      key,
    ])
  ).values()
);

const DEFAULT_API_KEY_VALUES: Record<string, string> = Object.fromEntries(
  MOCK_API_KEYS.map((key) => [key.envVar, ""])
);

const MOCK_API_KEY_PREFILL: Record<string, string> = {
  CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat01-...",
  ANTHROPIC_API_KEY: "sk-ant-api03-...",
  OPENAI_API_KEY: "sk-proj-...",
};

const HEATMAP_MODEL_OPTIONS = [
  { value: "anthropic-opus-4-5", label: "Claude Opus 4.5" },
  { value: "anthropic", label: "Claude Opus 4.1" },
  { value: "cmux-heatmap-2", label: "cmux-heatmap-2" },
  { value: "cmux-heatmap-1", label: "cmux-heatmap-1" },
];

const TOOLTIP_LANGUAGE_OPTIONS = [
  { value: "en", label: "English" },
  { value: "zh-Hant", label: "繁體中文" },
  { value: "zh-Hans", label: "简体中文" },
  { value: "ja", label: "日本語" },
  { value: "ko", label: "한국어" },
  { value: "es", label: "Español" },
  { value: "fr", label: "Français" },
  { value: "de", label: "Deutsch" },
  { value: "pt", label: "Português" },
  { value: "ru", label: "Русский" },
  { value: "vi", label: "Tiếng Việt" },
  { value: "th", label: "ไทย" },
  { value: "id", label: "Bahasa Indonesia" },
];

const sidebarTasks: SidebarTask[] = [
  {
    title: "Refactor Mac download...",
    status: "complete",
    expanded: true,
    runs: [
      {
        name: "claude/opus-4.5",
        status: "complete",
        children: [
          { type: "vscode", label: "VS Code" },
          { type: "diff", label: "Git diff" },
        ],
      },
      {
        name: "codex/gpt-5-high",
        status: "running",
        children: [
          { type: "vscode", label: "VS Code" },
          { type: "diff", label: "Git diff" },
        ],
      },
    ],
  },
  {
    title: "Configure API key helper",
    status: "running",
  },
  {
    title: "Implement Electron autoupdater",
    status: "pending",
  },
  {
    title: "Clean up onboarding flow",
    status: "complete",
  },
];

const taskCategories: TaskCategory[] = [
  {
    title: "Pinned",
    items: [
      {
        title: "we need to implement rsync between the local vscode to the cloud vscode for th...",
        repo: "cmux",
        time: "Jan 28",
        status: "success",
      },
      {
        title: "our normal git diff viewer should have the sidebar thing where we can easily filter...",
        repo: "cmux-helpers",
        time: "Jan 27",
        status: "success",
      },
      {
        title: "i think the trimming feature in the hostScreenshotCollector is too much...",
        repo: "cmux",
        time: "Jan 26",
        status: "success",
      },
      {
        title: "for some reason the cmux terminal is still not showing up all of the time...",
        repo: "cmux",
        time: "Jan 26",
        status: "success",
      },
      {
        title: "currently the host screenshot agent is calling a script to process the videos it ma...",
        repo: "cmux",
        time: "Jan 26",
        status: "success",
      },
    ],
  },
];

const runningCategories: TaskCategory[] = [
  {
    title: "In progress",
    items: [
      {
        title: "Fix auth bug (Claude)",
        repo: "cmux",
        time: "2m",
        status: "running",
      },
      {
        title: "Fix auth bug (Codex)",
        repo: "cmux",
        time: "3m",
        status: "running",
      },
      {
        title: "Fix auth bug (Gemini)",
        repo: "cmux",
        time: "Done",
        status: "success",
      },
    ],
  },
];

function GitHubIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true">
      <path
        fill="currentColor"
        d="M12 .5a11.5 11.5 0 00-3.64 22.41c.58.11.79-.25.79-.56v-2.17c-3.2.7-3.88-1.38-3.88-1.38-.53-1.33-1.3-1.68-1.3-1.68-1.06-.73.08-.72.08-.72 1.17.08 1.78 1.21 1.78 1.21 1.04 1.77 2.72 1.26 3.38.96.11-.76.41-1.26.75-1.55-2.56-.29-5.26-1.28-5.26-5.68 0-1.25.45-2.28 1.19-3.08-.12-.29-.52-1.46.11-3.05 0 0 .98-.31 3.2 1.18a11.1 11.1 0 015.83 0c2.22-1.49 3.2-1.18 3.2-1.18.63 1.59.23 2.76.11 3.05.74.8 1.19 1.83 1.19 3.08 0 4.41-2.7 5.39-5.27 5.67.42.36.8 1.07.8 2.16v3.2c0 .31.2.68.8.56A11.5 11.5 0 0012 .5z"
      />
    </svg>
  );
}

function OpenAIIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="118 120 480 480"
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M304.246 295.411V249.828C304.246 245.989 305.687 243.109 309.044 241.191L400.692 188.412C413.167 181.215 428.042 177.858 443.394 177.858C500.971 177.858 537.44 222.482 537.44 269.982C537.44 273.34 537.44 277.179 536.959 281.018L441.954 225.358C436.197 222 430.437 222 424.68 225.358L304.246 295.411ZM518.245 472.945V364.024C518.245 357.304 515.364 352.507 509.608 349.149L389.174 279.096L428.519 256.543C431.877 254.626 434.757 254.626 438.115 256.543L529.762 309.323C556.154 324.679 573.905 357.304 573.905 388.971C573.905 425.436 552.315 459.024 518.245 472.941V472.945ZM275.937 376.982L236.592 353.952C233.235 352.034 231.794 349.154 231.794 345.315V239.756C231.794 188.416 271.139 149.548 324.4 149.548C344.555 149.548 363.264 156.268 379.102 168.262L284.578 222.964C278.822 226.321 275.942 231.119 275.942 237.838V376.986L275.937 376.982ZM360.626 425.922L304.246 394.255V327.083L360.626 295.416L417.002 327.083V394.255L360.626 425.922ZM396.852 571.789C376.698 571.789 357.989 565.07 342.151 553.075L436.674 498.374C442.431 495.017 445.311 490.219 445.311 483.499V344.352L485.138 367.382C488.495 369.299 489.936 372.179 489.936 376.018V481.577C489.936 532.917 450.109 571.785 396.852 571.785V571.789ZM283.134 464.79L191.486 412.01C165.094 396.654 147.343 364.029 147.343 332.362C147.343 295.416 169.415 262.309 203.48 248.393V357.791C203.48 364.51 206.361 369.308 212.117 372.665L332.074 442.237L292.729 464.79C289.372 466.707 286.491 466.707 283.134 464.79ZM277.859 543.48C223.639 543.48 183.813 502.695 183.813 452.314C183.813 448.475 184.294 444.636 184.771 440.797L279.295 495.498C285.051 498.856 290.812 498.856 296.568 495.498L417.002 425.927V471.509C417.002 475.349 415.562 478.229 412.204 480.146L320.557 532.926C308.081 540.122 293.206 543.48 277.854 543.48H277.859ZM396.852 600.576C454.911 600.576 503.37 559.313 514.41 504.612C568.149 490.696 602.696 440.315 602.696 388.976C602.696 355.387 588.303 322.762 562.392 299.25C564.791 289.173 566.231 279.096 566.231 269.024C566.231 200.411 510.571 149.067 446.274 149.067C433.322 149.067 420.846 150.984 408.37 155.305C386.775 134.192 357.026 120.758 324.4 120.758C266.342 120.758 217.883 162.02 206.843 216.721C153.104 230.637 118.557 281.018 118.557 332.357C118.557 365.946 132.95 398.571 158.861 422.083C156.462 432.16 155.022 442.237 155.022 452.309C155.022 520.922 210.682 572.266 274.978 572.266C287.931 572.266 300.407 570.349 312.883 566.028C334.473 587.141 364.222 600.576 396.852 600.576Z" />
    </svg>
  );
}

function inferVendor(agentName: string): string {
  const lower = agentName.toLowerCase();
  if (lower.startsWith("codex/")) return "openai";
  if (lower.startsWith("claude/")) return "claude";
  if (lower.startsWith("gemini/")) return "gemini";
  if (lower.startsWith("opencode/")) return "opencode";
  if (lower.startsWith("qwen/")) return "qwen";
  if (lower.startsWith("cursor/")) return "cursor";
  if (lower.startsWith("amp")) return "amp";
  return "other";
}

function fallbackBadge(provider: string, className?: string) {
  const colors: Record<string, { bg: string; fg: string; label: string }> = {
    amp: { bg: "#7C3AED", fg: "#ffffff", label: "A" },
    opencode: { bg: "#111827", fg: "#ffffff", label: "OC" },
    cursor: { bg: "#0F172A", fg: "#ffffff", label: "C" },
    other: {
      bg: "#6B7280",
      fg: "#ffffff",
      label: provider[0]?.toUpperCase() || "?",
    },
  };
  const { bg, fg, label } = colors[provider] ?? colors.other;
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      className={className}
      aria-hidden
    >
      <rect x="0" y="0" width="16" height="16" rx="4" fill={bg} />
      <text
        x="8"
        y="8"
        textAnchor="middle"
        dominantBaseline="central"
        fill={fg}
        fontSize={label.length > 1 ? 7 : 9}
        fontFamily="Inter, ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, Apple Color Emoji, Segoe UI Emoji"
        fontWeight={700}
      >
        {label}
      </text>
    </svg>
  );
}

const AgentLogo = memo(function AgentLogo({
  agentName,
  className,
}: {
  agentName: string;
  className?: string;
}) {
  const vendor = inferVendor(agentName);

  if (vendor === "openai") {
    return <OpenAIIcon className={className} />;
  }
  if (vendor === "claude") {
    return (
      <svg viewBox="0 0 24 24" className={className} aria-hidden>
        <path
          d="M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"
          fill="#D97757"
          fillRule="nonzero"
        />
      </svg>
    );
  }
  if (vendor === "gemini") {
    return (
      <svg viewBox="0 0 16 16" className={className} aria-hidden>
        <path
          d="M16 8.016A8.522 8.522 0 008.016 16h-.032A8.521 8.521 0 000 8.016v-.032A8.521 8.521 0 007.984 0h.032A8.522 8.522 0 0016 7.984v.032z"
          fill="url(#gemini_radial)"
        />
        <defs>
          <radialGradient
            id="gemini_radial"
            cx="0"
            cy="0"
            r="1"
            gradientUnits="userSpaceOnUse"
            gradientTransform="matrix(16.1326 5.4553 -43.70045 129.2322 1.588 6.503)"
          >
            <stop offset=".067" stopColor="#9168C0" />
            <stop offset=".343" stopColor="#5684D1" />
            <stop offset=".672" stopColor="#1BA1E3" />
          </radialGradient>
        </defs>
      </svg>
    );
  }
  if (vendor === "qwen") {
    return (
      <svg viewBox="0 0 24 24" className={className} aria-hidden>
        <defs>
          <linearGradient id="qwen_grad" x1="0%" x2="100%" y1="0%" y2="0%">
            <stop offset="0%" stopColor="#6336E7" stopOpacity=".84" />
            <stop offset="100%" stopColor="#6F69F7" stopOpacity=".84" />
          </linearGradient>
        </defs>
        <path
          d="M12.604 1.34c.393.69.784 1.382 1.174 2.075a.18.18 0 00.157.091h5.552c.174 0 .322.11.446.327l1.454 2.57c.19.337.24.478.024.837-.26.43-.513.864-.76 1.3l-.367.658c-.106.196-.223.28-.04.512l2.652 4.637c.172.301.111.494-.043.77-.437.785-.882 1.564-1.335 2.34-.159.272-.352.375-.68.37-.777-.016-1.552-.01-2.327.016a.099.099 0 00-.081.05 575.097 575.097 0 01-2.705 4.74c-.169.293-.38.363-.725.364-.997.003-2.002.004-3.017.002a.537.537 0 01-.465-.271l-1.335-2.323a.09.09 0 00-.083-.049H4.982c-.285.03-.553-.001-.805-.092l-1.603-2.77a.543.543 0 01-.002-.54l1.207-2.12a.198.198 0 000-.197 550.951 550.951 0 01-1.875-3.272l-.79-1.395c-.16-.31-.173-.496.095-.965.465-.813.927-1.625 1.387-2.436.132-.234.304-.334.584-.335a338.3 338.3 0 012.589-.001.124.124 0 00.107-.063l2.806-4.895a.488.488 0 01.422-.246c.524-.001 1.053 0 1.583-.006L11.704 1c.341-.003.724.032.9.34zm-3.432.403a.06.06 0 00-.052.03L6.254 6.788a.157.157 0 01-.135.078H3.253c-.056 0-.07.025-.041.074l5.81 10.156c.025.042.013.062-.034.063l-2.795.015a.218.218 0 00-.2.116l-1.32 2.31c-.044.078-.021.118.068.118l5.716.008c.046 0 .08.02.104.061l1.403 2.454c.046.081.092.082.139 0l5.006-8.76.783-1.382a.055.055 0 01.096 0l1.424 2.53a.122.122 0 00.107.062l2.763-.02a.04.04 0 00.035-.02.041.041 0 000-.04l-2.9-5.086a.108.108 0 010-.113l.293-.507 1.12-1.977c.024-.041.012-.062-.035-.062H9.2c-.059 0-.073-.026-.043-.077l1.434-2.505a.107.107 0 000-.114L9.225 1.774a.06.06 0 00-.053-.031zm6.29 8.02c.046 0 .058.02.034.06l-.832 1.465-2.613 4.585a.056.056 0 01-.05.029.058.058 0 01-.05-.029L8.498 9.841c-.02-.034-.01-.052.028-.054l.216-.012 6.722-.012z"
          fill="url(#qwen_grad)"
          fillRule="nonzero"
        />
      </svg>
    );
  }
  if (vendor === "cursor") {
    return (
      <div className={clsx("bg-black rounded-lg", className)}>
        <div className="scale-70">
          <svg viewBox="0 0 24 24" aria-hidden>
            <defs>
              <linearGradient
                id="lobe-icons-cursorundefined-fill-0"
                x1="11.925"
                x2="11.925"
                y1="12"
                y2="24"
                gradientUnits="userSpaceOnUse"
              >
                <stop offset=".16" stopColor="#fff" stopOpacity=".39" />
                <stop offset=".658" stopColor="#fff" stopOpacity=".8" />
              </linearGradient>
              <linearGradient
                id="lobe-icons-cursorundefined-fill-1"
                x1="22.35"
                x2="11.925"
                y1="6.037"
                y2="12.15"
                gradientUnits="userSpaceOnUse"
              >
                <stop offset=".182" stopColor="#fff" stopOpacity=".31" />
                <stop offset=".715" stopColor="#fff" stopOpacity="0" />
              </linearGradient>
              <linearGradient
                id="lobe-icons-cursorundefined-fill-2"
                x1="11.925"
                x2="1.5"
                y1="0"
                y2="18"
                gradientUnits="userSpaceOnUse"
              >
                <stop stopColor="#fff" stopOpacity=".6" />
                <stop offset=".667" stopColor="#fff" stopOpacity=".22" />
              </linearGradient>
            </defs>
            <path
              d="M11.925 24l10.425-6-10.425-6L1.5 18l10.425 6z"
              fill="url(#lobe-icons-cursorundefined-fill-0)"
            />
            <path
              d="M22.35 18V6L11.925 0v12l10.425 6z"
              fill="url(#lobe-icons-cursorundefined-fill-1)"
            />
            <path
              d="M11.925 0L1.5 6v12l10.425-6V0z"
              fill="url(#lobe-icons-cursorundefined-fill-2)"
            />
          </svg>
        </div>
      </div>
    );
  }

  return fallbackBadge(vendor, className);
});

function FakeSingleSelect({
  options,
  value,
  onChange,
  placeholder,
  leadingIcon,
  className,
  footer,
  showSearch = false,
  searchPlaceholder = "Search...",
  popoverClassName,
}: {
  options: FakeSelectOption[];
  value: string | null;
  onChange: (value: string) => void;
  placeholder: string;
  leadingIcon?: ReactNode;
  className?: string;
  footer?: ReactNode;
  showSearch?: boolean;
  searchPlaceholder?: string;
  popoverClassName?: string;
}) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const containerRef = useRef<HTMLDivElement | null>(null);
  const selectedOption = options.find((option) => option.value === value) ?? null;
  const displayIcon = selectedOption?.icon ?? leadingIcon;
  const filteredOptions = useMemo(() => {
    if (!showSearch) return options;
    const q = search.trim().toLowerCase();
    if (!q) return options;
    return options.filter(
      (option) =>
        !option.heading && option.label.toLowerCase().includes(q)
    );
  }, [options, search, showSearch]);

  useEffect(() => {
    if (!open) return;
    const handleClick = (event: MouseEvent) => {
      if (!(event.target instanceof Node)) return;
      if (containerRef.current?.contains(event.target)) return;
      setOpen(false);
    };
    window.addEventListener("mousedown", handleClick);
    return () => window.removeEventListener("mousedown", handleClick);
  }, [open]);

  useEffect(() => {
    if (open) return;
    setSearch("");
  }, [open]);

  return (
    <div ref={containerRef} className="relative inline-flex items-center">
      <button
        className={clsx(
          "relative inline-flex h-7 items-center rounded-md border border-neutral-200 bg-white px-2.5 pr-6 text-sm text-neutral-900 transition-colors outline-none focus:outline-none focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-800 dark:bg-neutral-950 dark:text-neutral-100 aria-expanded:bg-neutral-50 dark:aria-expanded:bg-neutral-900 w-auto select-none",
          className
        )}
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((prev) => !prev)}
      >
        <span className="flex-1 min-w-0 text-left text-[13.5px] inline-flex items-center gap-1.5 pr-1 tabular-nums">
          {displayIcon ? (
            <span className="shrink-0 inline-flex items-center justify-center">
              {displayIcon}
            </span>
          ) : null}
          {selectedOption ? (
            <span className="truncate select-none">{selectedOption.label}</span>
          ) : (
            <span className="text-neutral-400 truncate select-none">
              {placeholder}
            </span>
          )}
        </span>
        <ChevronDown className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-neutral-500" />
      </button>
      {open ? (
        <div
          className={clsx(
            "absolute left-0 top-full mt-2 z-50 w-[300px] rounded-md border overflow-hidden border-neutral-200 bg-white p-0 shadow-lg dark:border-neutral-800 dark:bg-neutral-950",
            popoverClassName
          )}
        >
          {showSearch ? (
            <div className="px-2 py-2 border-b border-neutral-200 dark:border-neutral-800">
              <input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder={searchPlaceholder}
                className="w-full bg-transparent text-[13.5px] text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 outline-none"
              />
            </div>
          ) : null}
          <div className="max-h-[18rem] overflow-y-auto p-1">
            {filteredOptions.length === 0 ? (
              <div className="px-3 py-4 text-[13.5px] text-neutral-500 dark:text-neutral-400 select-none">
                No options
              </div>
            ) : (
              filteredOptions.map((option) => {
                if (option.heading) {
                  return (
                    <div
                      key={`heading-${option.value}`}
                      className="flex items-center gap-2 min-w-0 flex-1 pl-1 pr-3 py-1 h-[28px] text-[11px] font-semibold text-neutral-500 dark:text-neutral-400"
                    >
                      {option.icon ? (
                        <span className="shrink-0 inline-flex items-center justify-center">
                          {option.icon}
                        </span>
                      ) : null}
                      <span className="truncate select-none">{option.label}</span>
                    </div>
                  );
                }
                const isDisabled = option.disabled;
                return (
                  <button
                    key={option.value}
                    type="button"
                    disabled={isDisabled}
                    onClick={() => {
                      if (isDisabled) return;
                      onChange(option.value);
                      setOpen(false);
                    }}
                    className={clsx(
                      "w-full px-2 h-[32px] flex items-center justify-between gap-2 text-[13.5px] rounded-sm cursor-default transition-colors select-none outline-none focus-visible:outline-none",
                      "text-neutral-900 dark:text-neutral-100",
                      "hover:bg-neutral-100 dark:hover:bg-neutral-800",
                      option.value === value && "bg-neutral-100 dark:bg-neutral-800",
                      isDisabled && "opacity-60 cursor-not-allowed"
                    )}
                  >
                    <span className="flex items-center gap-2 min-w-0 flex-1">
                      {option.icon ? (
                        <span className="inline-flex items-center justify-center">
                          {option.icon}
                        </span>
                      ) : null}
                      <span className="truncate select-none">{option.label}</span>
                    </span>
                    {option.value === value ? (
                      <Check className="h-4 w-4 text-neutral-900 dark:text-neutral-100" />
                    ) : null}
                  </button>
                );
              })
            )}
          </div>
          {footer ? (
            <div className="border-t border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 min-h-[40.5px]">
              {footer}
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function FakeMultiSelect({
  options,
  value,
  onChange,
  placeholder,
  countLabel = "agents",
  className,
  footer,
  showSearch = false,
  searchPlaceholder = "Search...",
  popoverClassName,
}: {
  options: FakeSelectOption[];
  value: string[];
  onChange: (value: string[]) => void;
  placeholder: string;
  countLabel?: string;
  className?: string;
  footer?: ReactNode;
  showSearch?: boolean;
  searchPlaceholder?: string;
  popoverClassName?: string;
}) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const containerRef = useRef<HTMLDivElement | null>(null);
  const valueSet = useMemo(() => new Set(value), [value]);
  const valueToOption = useMemo(
    () => new Map(options.map((option) => [option.value, option] as const)),
    [options]
  );
  const firstSelected = value[0] ? valueToOption.get(value[0]) ?? null : null;
  const selectedWithIcons = useMemo(
    () =>
      value
        .map((val) => {
          const opt = valueToOption.get(val);
          if (!opt?.icon) return null;
          return { key: opt.iconKey ?? val, icon: opt.icon };
        })
        .filter(Boolean) as Array<{ key: string; icon: ReactNode }>,
    [value, valueToOption]
  );
  const uniqueIcons = useMemo(() => {
    const seen = new Set<string>();
    const icons: ReactNode[] = [];
    for (const item of selectedWithIcons) {
      if (seen.has(item.key)) continue;
      seen.add(item.key);
      icons.push(item.icon);
    }
    return icons;
  }, [selectedWithIcons]);
  const filteredOptions = useMemo(() => {
    if (!showSearch) return options;
    const q = search.trim().toLowerCase();
    if (!q) return options;
    return options.filter(
      (option) =>
        !option.heading && option.label.toLowerCase().includes(q)
    );
  }, [options, search, showSearch]);

  useEffect(() => {
    if (!open) return;
    const handleClick = (event: MouseEvent) => {
      if (!(event.target instanceof Node)) return;
      if (containerRef.current?.contains(event.target)) return;
      setOpen(false);
    };
    window.addEventListener("mousedown", handleClick);
    return () => window.removeEventListener("mousedown", handleClick);
  }, [open]);

  useEffect(() => {
    if (open) return;
    setSearch("");
  }, [open]);

  const toggleValue = (val: string) => {
    if (valueSet.has(val)) {
      onChange(value.filter((entry) => entry !== val));
      return;
    }
    onChange([...value, val]);
  };

  return (
    <div ref={containerRef} className="relative inline-flex items-center">
      <button
        className={clsx(
          "relative inline-flex h-7 items-center rounded-md border border-neutral-200 bg-white px-2.5 pr-6 text-sm text-neutral-900 transition-colors outline-none focus:outline-none focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-800 dark:bg-neutral-950 dark:text-neutral-100 aria-expanded:bg-neutral-50 dark:aria-expanded:bg-neutral-900 w-auto select-none",
          className
        )}
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((prev) => !prev)}
      >
        <span className="flex-1 min-w-0 text-left text-[13.5px] inline-flex items-center gap-1.5 pr-1 tabular-nums">
          {value.length === 0 ? (
            <span className="text-neutral-400 truncate select-none">
              {placeholder}
            </span>
          ) : value.length === 1 && firstSelected ? (
            <>
              {firstSelected.icon ? (
                <span className="shrink-0 inline-flex items-center justify-center">
                  {firstSelected.icon}
                </span>
              ) : null}
              <span className="truncate select-none">{firstSelected.label}</span>
            </>
          ) : uniqueIcons.length > 0 ? (
            <>
              <span className="flex space-x-[2px]">
                {uniqueIcons.slice(0, 5).map((icon, index) => (
                  <span
                    key={index}
                    className="inline-flex h-4 w-4 items-center justify-center overflow-hidden"
                  >
                    {icon}
                  </span>
                ))}
              </span>
              <span className="truncate select-none">{`${value.length} ${countLabel}`}</span>
            </>
          ) : (
            <span className="truncate select-none">{`${value.length} ${countLabel}`}</span>
          )}
        </span>
        <ChevronDown className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-neutral-500" />
      </button>
      {open ? (
        <div
          className={clsx(
            "absolute left-0 top-full mt-2 z-50 w-[315px] rounded-md border overflow-hidden border-neutral-200 bg-white p-0 shadow-lg dark:border-neutral-800 dark:bg-neutral-950",
            popoverClassName
          )}
        >
          {showSearch ? (
            <div className="px-2 py-2 border-b border-neutral-200 dark:border-neutral-800">
              <input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder={searchPlaceholder}
                className="w-full bg-transparent text-[13.5px] text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 outline-none"
              />
            </div>
          ) : null}
          <div className="max-h-[18rem] overflow-y-auto p-1">
            {filteredOptions.length === 0 ? (
              <div className="px-3 py-4 text-[13.5px] text-neutral-500 dark:text-neutral-400 select-none">
                No options
              </div>
            ) : (
              filteredOptions.map((option) => {
                if (option.heading) {
                  return (
                    <div
                      key={`heading-${option.value}`}
                      className="flex items-center gap-2 min-w-0 flex-1 pl-1 pr-3 py-1 h-[28px] text-[11px] font-semibold text-neutral-500 dark:text-neutral-400"
                    >
                      {option.icon ? (
                        <span className="shrink-0 inline-flex items-center justify-center">
                          {option.icon}
                        </span>
                      ) : null}
                      <span className="truncate select-none">{option.label}</span>
                    </div>
                  );
                }
                const selected = valueSet.has(option.value);
                const isDisabled = option.disabled;
                return (
                  <button
                    key={option.value}
                    type="button"
                    disabled={isDisabled}
                    onClick={() => {
                      if (isDisabled) return;
                      toggleValue(option.value);
                    }}
                    className={clsx(
                      "w-full px-2 h-[32px] flex items-center justify-between gap-2 text-[13.5px] rounded-sm cursor-default transition-colors select-none outline-none focus-visible:outline-none",
                      "text-neutral-900 dark:text-neutral-100",
                      "hover:bg-neutral-100 dark:hover:bg-neutral-800",
                      selected && "bg-neutral-100 dark:bg-neutral-800",
                      isDisabled && "opacity-60 cursor-not-allowed"
                    )}
                  >
                    <span className="flex items-center gap-2 min-w-0 flex-1">
                      {option.icon ? (
                        <span className="inline-flex items-center justify-center">
                          {option.icon}
                        </span>
                      ) : null}
                      <span className="truncate select-none">{option.label}</span>
                    </span>
                    {selected ? (
                      <Check className="h-4 w-4 text-neutral-900 dark:text-neutral-100" />
                    ) : null}
                  </button>
                );
              })
            )}
          </div>
          {footer ? (
            <div className="border-t border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 min-h-[40.5px]">
              {footer}
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function SidebarNavItem({
  item,
  active,
  onClick,
}: {
  item: NavItem;
  active: boolean;
  onClick: () => void;
}) {
  const Icon = item.icon;
  return (
    <button
      type="button"
      className={clsx(
        "group flex items-center gap-2 rounded-sm pl-2 ml-2 py-1 text-[13px] select-none pr-2 transition-colors text-left w-[calc(100%-0.5rem)]",
        "hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45",
        active
          ? "bg-neutral-200/75 text-black dark:bg-neutral-800/65 dark:text-white"
          : "text-neutral-900 dark:text-neutral-100"
      )}
      data-active={active ? "true" : undefined}
      aria-current={active ? "page" : undefined}
      onClick={onClick}
    >
      <Icon
        className={
          "size-[15px] text-neutral-500 group-hover:text-neutral-800 dark:group-hover:text-neutral-100 group-data-[active=true]:text-neutral-900 dark:group-data-[active=true]:text-neutral-100"
        }
        aria-hidden
      />
      <span>{item.label}</span>
    </button>
  );
}

function SidebarToggleButton({
  expanded,
  visible,
}: {
  expanded: boolean;
  visible: boolean;
}) {
  return (
    <div
      className={clsx(
        "grid place-content-center rounded cursor-default transition-colors size-4",
        !visible && "invisible"
      )}
    >
      <ChevronRight
        className={clsx(
          "transition-transform w-3 h-3 text-neutral-500",
          expanded && "rotate-90"
        )}
      />
    </div>
  );
}

function SidebarListItem({
  title,
  secondary,
  meta,
  paddingLeft = 8,
  toggleVisible = false,
  expanded = false,
  titleClassName,
}: {
  title: ReactNode;
  secondary?: ReactNode;
  meta?: ReactNode;
  paddingLeft?: number;
  toggleVisible?: boolean;
  expanded?: boolean;
  titleClassName?: string;
}) {
  const effectivePaddingLeft = Math.max(0, toggleVisible ? paddingLeft - 4 : paddingLeft);
  return (
    <div className="relative group select-none">
      <div
        className={clsx(
          "flex items-center rounded-sm pr-2 py-[3px] text-xs",
          "hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45 cursor-default"
        )}
        style={{ paddingLeft: `${effectivePaddingLeft}px` }}
      >
        {toggleVisible ? (
          <div className="pr-1 -ml-0.5 relative">
            <SidebarToggleButton expanded={expanded} visible={toggleVisible} />
          </div>
        ) : null}
        <div className="flex-1 min-w-0 gap-px">
          <div className="flex items-center gap-2 min-w-0">
            <span
              className={clsx(
                "truncate text-neutral-900 dark:text-neutral-100 font-medium",
                titleClassName
              )}
            >
              {title}
            </span>
            {meta ? <span className="ml-auto flex-shrink-0">{meta}</span> : null}
          </div>
          {secondary ? (
            <div className="truncate text-[10px] text-neutral-600 dark:text-neutral-400">
              {secondary}
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}

function SidebarStatusIcon({ status }: { status: TaskStatus }) {
  if (status === "complete") {
    return <CheckCircle className="w-3 h-3 text-green-500" />;
  }
  if (status === "running") {
    return <Circle className="w-3 h-3 text-neutral-400 animate-pulse" />;
  }
  return <Circle className="w-3 h-3 text-neutral-400" />;
}

function PullRequestIcon({ status }: { status: PullRequestStatus }) {
  if (status === "merged") {
    return <GitMerge className="w-3 h-3 text-purple-500" />;
  }
  if (status === "draft") {
    return <GitPullRequestDraft className="w-3 h-3 text-neutral-500" />;
  }
  return <GitPullRequest className="w-3 h-3 text-[#1f883d] dark:text-[#238636]" />;
}

function TaskRowStatusDot({ status }: { status: TaskRowStatus }) {
  if (status === "success") {
    return <span className="w-[8px] h-[8px] rounded-full bg-green-500" />;
  }
  if (status === "running") {
    return <span className="w-[9.5px] h-[9.5px] rounded-full bg-blue-500" />;
  }
  if (status === "blocked") {
    return <span className="w-[9.5px] h-[9.5px] rounded-full bg-orange-500" />;
  }
  return (
    <span className="w-[9.5px] h-[9.5px] rounded-full border border-neutral-400 dark:border-neutral-500 bg-transparent" />
  );
}

function TaskTabs({ active }: { active: "tasks" | "previews" | "archived" }) {
  const tabClass = (tab: "tasks" | "previews" | "archived") =>
    clsx(
      "text-sm font-medium transition-colors",
      active === tab
        ? "text-neutral-900 dark:text-neutral-100"
        : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200"
    );
  return (
    <div className="mb-3 px-4">
      <div className="flex items-end gap-2.5 select-none">
        <button className={tabClass("tasks")} type="button">
          Tasks
        </button>
        <button className={tabClass("previews")} type="button">
          Previews
        </button>
        <button className={tabClass("archived")} type="button">
          Archived
        </button>
      </div>
    </div>
  );
}

function TaskCategorySection({ category }: { category: TaskCategory }) {
  return (
    <div className="w-full">
      <div className="sticky top-0 z-10 flex w-full border-y border-neutral-200 dark:border-neutral-900 bg-neutral-100 dark:bg-neutral-800 select-none">
        <div className="flex w-full items-center pr-4">
          <button
            className="flex h-9 w-9 items-center justify-center text-neutral-500 hover:text-black dark:text-neutral-400 dark:hover:text-neutral-200 transition-colors"
            type="button"
          >
            <ChevronRight className="h-3 w-3 rotate-90" />
          </button>
          <div className="flex items-center gap-2 text-xs font-medium tracking-tight text-neutral-900 dark:text-neutral-100">
            <span>{category.title}</span>
            <span className="text-xs text-neutral-500 dark:text-neutral-400">
              {category.items.length}
            </span>
          </div>
        </div>
      </div>
      <div className="flex flex-col w-full">
        {category.items.map((task) => (
          <div
            key={`${task.title}-${task.time}`}
            className={clsx(
              "relative grid w-full items-center py-2 pr-3 cursor-default select-none group",
              "grid-cols-[24px_36px_1fr_minmax(120px,auto)_58px]",
              "bg-white dark:bg-neutral-900/50 group-hover:bg-neutral-50/90 dark:group-hover:bg-neutral-600/60"
            )}
          >
            <div className="flex items-center justify-center pl-1 -mr-2 relative">
              <input
                type="checkbox"
                className="peer w-3 h-3 cursor-pointer border border-neutral-400 dark:border-neutral-500 rounded bg-white dark:bg-neutral-900 appearance-none checked:bg-neutral-500 checked:border-neutral-500 dark:checked:bg-neutral-400 dark:checked:border-neutral-400 invisible"
                onChange={() => undefined}
              />
              <Check
                className="absolute w-2.5 h-2.5 text-white pointer-events-none transition-opacity peer-checked:opacity-100 opacity-0"
                style={{
                  left: "57%",
                  top: "50%",
                  transform: "translate(-50%, -50%)",
                }}
              />
            </div>
            <div className="flex items-center justify-center">
              <TaskRowStatusDot status={task.status} />
            </div>
            <div className="min-w-0 flex items-center">
              <span className="text-[13px] font-medium truncate min-w-0 pr-1 text-neutral-900 dark:text-neutral-100">
                {task.title}
              </span>
            </div>
            <div className="text-[11px] text-neutral-500 dark:text-neutral-400 min-w-0 text-right">
              {task.repo}
            </div>
            <div className="text-[11px] text-neutral-500 dark:text-neutral-400 flex-shrink-0 tabular-nums text-right">
              {task.time}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function ModeToggleMock({ disabled = false }: { disabled?: boolean }) {
  const [isCloudMode, setIsCloudMode] = useState(true);
  const [showTooltip, setShowTooltip] = useState(false);
  const tooltipTimeoutRef = useRef<number | null>(null);

  useEffect(() => {
    return () => {
      if (tooltipTimeoutRef.current !== null) {
        window.clearTimeout(tooltipTimeoutRef.current);
      }
    };
  }, []);

  const hideTooltip = () => {
    setShowTooltip(false);
  };

  const showTooltipBriefly = () => {
    setShowTooltip(true);
    if (tooltipTimeoutRef.current !== null) {
      window.clearTimeout(tooltipTimeoutRef.current);
    }
    tooltipTimeoutRef.current = window.setTimeout(() => {
      tooltipTimeoutRef.current = null;
      hideTooltip();
    }, 2000);
  };

  const handleToggle = () => {
    if (disabled) return;
    setIsCloudMode((prev) => !prev);
    showTooltipBriefly();
  };

  const handleMouseEnter = () => {
    if (tooltipTimeoutRef.current !== null) {
      window.clearTimeout(tooltipTimeoutRef.current);
      tooltipTimeoutRef.current = null;
    }
    setShowTooltip(true);
  };

  const handleMouseLeave = () => {
    hideTooltip();
  };

  return (
    <div
      className="relative inline-flex items-center"
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      <button
        type="button"
        role="switch"
        aria-checked={isCloudMode}
        aria-label={isCloudMode ? "Cloud mode" : "Local mode"}
        data-selected={isCloudMode ? "true" : "false"}
        onClick={handleToggle}
        className={clsx(
          "group relative max-w-fit inline-flex items-center justify-start cursor-pointer touch-none tap-highlight-transparent select-none",
          "disabled:cursor-default disabled:opacity-60",
          disabled && "cursor-default"
        )}
        disabled={disabled}
      >
        <span
          className={clsx(
            "px-1 relative inline-flex items-center justify-start shrink-0 overflow-hidden rounded-full transition-background",
            "w-10 h-6",
            "bg-neutral-200 dark:bg-neutral-800 border border-transparent",
            "group-data-[selected=true]:bg-blue-500 group-data-[selected=true]:border-blue-500"
          )}
        >
          <span
            className={clsx(
              "z-10 flex items-center justify-center bg-white shadow-sm rounded-full origin-right pointer-events-none transition-all",
              "w-4 h-4 text-[10px]",
              "group-data-[selected=true]:ml-4"
            )}
          >
            {isCloudMode ? (
              <Cloud className="size-3 text-black" />
            ) : (
              <HardDrive className="size-3 text-black" />
            )}
          </span>
        </span>
      </button>

      {showTooltip ? (
        <div className="absolute top-full left-1/2 -translate-x-1/2 z-50 mt-2">
          <div className="absolute left-[calc(50%_-4px)] translate-y-[calc(-50%_+1px)] size-2.5 rounded-[2px] rotate-45 bg-black" />
          <div className="relative px-3 py-1.5 bg-black text-white text-xs rounded-md whitespace-nowrap overflow-hidden w-24">
            <div className="relative h-4 flex items-center w-full select-none">
              <div className="relative w-full flex">
                <span
                  className={clsx(
                    "flex items-center justify-center absolute inset-0 transition-transform duration-200 ease-in-out",
                    isCloudMode ? "translate-x-0" : "translate-x-[150%]"
                  )}
                >
                  Cloud Mode
                </span>
                <span
                  className={clsx(
                    "flex items-center justify-center absolute inset-0 transition-transform duration-200 ease-in-out",
                    isCloudMode ? "-translate-x-[150%]" : "translate-x-0"
                  )}
                >
                  Local Mode
                </span>
              </div>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function DashboardInputControlsMock() {
  const projectOptions = useMemo<FakeSelectOption[]>(
    () => {
      const environmentOptions: FakeSelectOption[] = [
        {
          value: "env:devbox",
          label: "Devbox",
          icon: (
            <Tooltip>
              <TooltipTrigger asChild>
                <span>
                  <Server className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
                </span>
              </TooltipTrigger>
              <TooltipContent>Environment: Devbox</TooltipContent>
            </Tooltip>
          ),
          iconKey: "environment",
        },
        {
          value: "env:desktop-app",
          label: "Desktop app",
          icon: (
            <Tooltip>
              <TooltipTrigger asChild>
                <span>
                  <Server className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
                </span>
              </TooltipTrigger>
              <TooltipContent>Environment: Desktop app</TooltipContent>
            </Tooltip>
          ),
          iconKey: "environment",
        },
      ];

      const repoOptions: FakeSelectOption[] = [
        {
          value: "manaflow-ai/cmux",
          label: "manaflow-ai/cmux",
          icon: (
            <GitHubIcon className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
          ),
          iconKey: "github",
        },
        {
          value: "cmux/devbox-v1",
          label: "cmux/devbox-v1",
          icon: (
            <GitHubIcon className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
          ),
          iconKey: "github",
        },
        {
          value: "cmux/desktop-app",
          label: "cmux/desktop-app",
          icon: (
            <GitHubIcon className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
          ),
          iconKey: "github",
        },
        {
          value: "cmux/infra",
          label: "cmux/infra",
          icon: (
            <GitHubIcon className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
          ),
          iconKey: "github",
        },
      ];

      const options: FakeSelectOption[] = [];
      if (environmentOptions.length > 0) {
        options.push({
          value: "__heading-env",
          label: "Environments",
          heading: true,
        });
        options.push(...environmentOptions);
      }
      if (repoOptions.length > 0) {
        options.push({
          value: "__heading-repo",
          label: "Repositories",
          heading: true,
        });
        options.push(...repoOptions);
      }
      return options;
    },
    []
  );

  const branchOptions = useMemo<FakeSelectOption[]>(
    () => [
      { value: "main", label: "main" },
      { value: "release/2026-01-30", label: "release/2026-01-30" },
      { value: "feat/sidebar-sync", label: "feat/sidebar-sync" },
      { value: "fix/terminal-panel", label: "fix/terminal-panel" },
    ],
    []
  );

  const agentOptions = useMemo<FakeSelectOption[]>(
    () =>
      AGENT_CONFIGS.map((agent) => ({
        value: agent.name,
        label: agent.name,
        icon: <AgentLogo agentName={agent.name} className="w-4 h-4" />,
        iconKey: inferVendor(agent.name),
      })),
    []
  );

  const defaultAgent = useMemo(() => {
    const preferred = AGENT_CONFIGS.find(
      (agent) => agent.name === "claude/opus-4.5"
    );
    return preferred?.name ?? AGENT_CONFIGS[0]?.name ?? "";
  }, []);

  const defaultProject = useMemo(
    () => projectOptions.find((option) => option.value === "manaflow-ai/cmux")?.value ?? projectOptions.find((option) => !option.heading)?.value ?? "",
    [projectOptions]
  );

  const [selectedProject, setSelectedProject] = useState(defaultProject);
  const [selectedBranch, setSelectedBranch] = useState<string>(
    branchOptions[0]?.value ?? ""
  );
  const [selectedAgents, setSelectedAgents] = useState<string[]>(
    defaultAgent ? [defaultAgent] : []
  );
  const [showCustomRepoInput, setShowCustomRepoInput] = useState(false);
  const [customRepoUrl, setCustomRepoUrl] = useState("");

  const isEnvSelected = selectedProject.startsWith("env:");
  const agentOptionsByValue = useMemo(
    () => new Map(agentOptions.map((option) => [option.value, option] as const)),
    [agentOptions]
  );

  const repoFooter = (
    <div className="p-1">
      <button
        type="button"
        className="w-full px-2 h-8 flex items-center gap-2 text-[13.5px] text-neutral-800 dark:text-neutral-200 rounded-md hover:bg-neutral-50 dark:hover:bg-neutral-900 cursor-default"
      >
        <Server className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
        <span className="select-none">Create environment</span>
      </button>
      <button
        type="button"
        className="w-full px-2 h-8 flex items-center gap-2 text-[13.5px] text-neutral-800 dark:text-neutral-200 rounded-md hover:bg-neutral-50 dark:hover:bg-neutral-900"
      >
        <GitHubIcon className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
        <span className="select-none">Add repos from GitHub</span>
      </button>
      <button
        type="button"
        onClick={() => setShowCustomRepoInput((prev) => !prev)}
        className="w-full px-2 h-8 flex items-center gap-2 text-[13.5px] text-neutral-800 dark:text-neutral-200 rounded-md hover:bg-neutral-50 dark:hover:bg-neutral-900"
      >
        <Link2 className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
        <span className="select-none">
          {showCustomRepoInput ? "Hide repo link menu" : "Import repos from link"}
        </span>
      </button>
      {showCustomRepoInput ? (
        <div className="px-2 pb-2 pt-1">
          <div className="flex gap-1">
            <input
              type="text"
              value={customRepoUrl}
              onChange={(event) => setCustomRepoUrl(event.target.value)}
              placeholder="github.com/owner/repo"
              className={clsx(
                "flex-1 px-2 h-7 text-[13px] rounded border",
                "bg-white dark:bg-neutral-800",
                "border-neutral-300 dark:border-neutral-600",
                "text-neutral-900 dark:text-neutral-100",
                "placeholder:text-neutral-400 dark:placeholder:text-neutral-500",
                "focus:outline-none focus:ring-1 focus:ring-blue-500"
              )}
            />
            <button
              type="button"
              className={clsx(
                "px-2 h-7 flex items-center justify-center rounded",
                "bg-blue-500 hover:bg-blue-600",
                "text-white text-[12px] font-medium",
                "transition-colors"
              )}
              title="Add repository"
            >
              <Check className="w-3.5 h-3.5" />
            </button>
          </div>
          <p className="text-[10px] text-neutral-500 dark:text-neutral-400 mt-1 px-1">
            Enter any GitHub repository link
          </p>
        </div>
      ) : null}
    </div>
  );

  const agentSelectionFooter = selectedAgents.length ? (
    <div className="bg-neutral-50 dark:bg-neutral-900/70">
      <div className="max-h-32 overflow-y-auto py-2 px-2">
        <div className="flex flex-wrap gap-1">
          {selectedAgents.map((agentName) => {
            const option = agentOptionsByValue.get(agentName);
            const label = option?.label ?? agentName;
            const displayLabel = label.includes("/")
              ? label.slice(label.indexOf("/") + 1)
              : label;
            return (
              <div
                key={agentName}
                className="inline-flex cursor-default items-center rounded-full bg-neutral-200/70 dark:bg-neutral-800/80 pl-1.5 pr-2 py-1 text-[11px] text-neutral-700 dark:text-neutral-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/60 hover:bg-neutral-200 dark:hover:bg-neutral-700/80"
              >
                <button
                  type="button"
                  onClick={(event) => {
                    event.preventDefault();
                    event.stopPropagation();
                    setSelectedAgents((prev) =>
                      prev.filter((entry) => entry !== agentName)
                    );
                  }}
                  className="inline-flex h-4 w-4 items-center justify-center rounded-full transition-colors hover:bg-neutral-400/30 dark:hover:bg-neutral-500/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/60"
                >
                  <X className="h-3 w-3" aria-hidden="true" />
                  <span className="sr-only">Remove {displayLabel}</span>
                </button>
                {option?.icon ? (
                  <span className="inline-flex h-3.5 w-3.5 items-center justify-center ml-0.5">
                    {option.icon}
                  </span>
                ) : null}
                <span className="max-w-[118px] truncate text-left select-none ml-1.5">
                  {displayLabel}
                </span>
                <span className="inline-flex min-w-[1.125rem] items-center justify-center rounded-full bg-neutral-300/80 px-1 text-[10px] font-semibold leading-4 text-neutral-700 dark:bg-neutral-700/70 dark:text-neutral-100 ml-1.5 tabular-nums select-none">
                  1
                </span>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  ) : (
    <div className="px-3 flex items-center text-[12px] text-neutral-500 dark:text-neutral-400 bg-neutral-50 dark:bg-neutral-900/70 h-[40.5px] select-none">
      No agents selected yet.
    </div>
  );

  return (
    <TooltipProvider>
      <div className="flex items-end gap-1 grow min-w-0">
        <div className="flex items-end gap-1 min-w-0">
          <FakeSingleSelect
            options={projectOptions}
            value={selectedProject}
            onChange={setSelectedProject}
            placeholder="Select project"
            className="rounded-2xl max-w-[240px] min-w-0"
            showSearch
            searchPlaceholder="Search or paste a repo link..."
            footer={repoFooter}
          />
          {isEnvSelected ? null : (
            <Tooltip>
              <TooltipTrigger asChild>
                <div>
                  <FakeSingleSelect
                    options={branchOptions}
                    value={selectedBranch}
                    onChange={setSelectedBranch}
                    placeholder="Branch"
                    className="rounded-2xl max-w-[160px] min-w-0"
                    leadingIcon={
                      <GitBranch className="w-4 h-4 text-neutral-500 dark:text-neutral-400" />
                    }
                    showSearch
                    searchPlaceholder="Search..."
                  />
                </div>
              </TooltipTrigger>
              <TooltipContent>Branch this task starts from</TooltipContent>
            </Tooltip>
          )}
          <FakeMultiSelect
            options={agentOptions}
            value={selectedAgents}
            onChange={setSelectedAgents}
            placeholder="Select agents"
            countLabel="agents"
            className="rounded-2xl max-w-[260px] min-w-0"
            showSearch
            searchPlaceholder="Search..."
            popoverClassName="w-[315px]"
            footer={agentSelectionFooter}
          />
        </div>

        <div className="flex items-center justify-end gap-2.5 ml-auto mr-0 pr-1">
          <ModeToggleMock disabled={isEnvSelected} />

          <button
            className={clsx(
              "p-1.5 rounded-full",
              "bg-neutral-100 dark:bg-neutral-700",
              "border border-neutral-200 dark:border-neutral-500/15",
              "text-neutral-600 dark:text-neutral-400",
              "hover:bg-neutral-200 dark:hover:bg-neutral-600",
              "transition-colors"
            )}
            type="button"
            title="Upload image"
          >
            <ImageIcon className="w-4 h-4" />
          </button>

          <button
            className={clsx(
              "p-1.5 rounded-full",
              "bg-neutral-100 dark:bg-neutral-700",
              "border border-neutral-200 dark:border-neutral-500/15",
              "text-neutral-600 dark:text-neutral-400",
              "hover:bg-neutral-200 dark:hover:bg-neutral-600",
              "transition-colors"
            )}
            type="button"
            title="Voice input"
          >
            <Mic className="w-4 h-4" />
          </button>
        </div>
      </div>
    </TooltipProvider>
  );
}

function StartTaskButton() {
  const isMac =
    typeof navigator !== "undefined" &&
    navigator.userAgent.toUpperCase().includes("MAC");

  return (
    <Tooltip delayDuration={0}>
      <TooltipTrigger asChild>
        <span className="inline-flex" tabIndex={0} data-onboarding="start-button">
          <a
            href="https://cmux.sh"
            className={clsx(
              "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-all",
              "h-7 px-3 shadow-xs",
              "bg-neutral-900 text-white hover:bg-neutral-800",
              "dark:bg-[oklch(0.45_0.15_240)] dark:text-white dark:hover:bg-[oklch(0.45_0.15_240/0.9)]",
              "focus-visible:ring-offset-1 focus-visible:ring-offset-white dark:focus-visible:ring-offset-neutral-900"
            )}
          >
            Start task
          </a>
        </span>
      </TooltipTrigger>
      <TooltipContent
        side="bottom"
        className="flex items-center gap-1 bg-black text-white border-black [&>*:last-child]:bg-black [&>*:last-child]:fill-black"
      >
        {isMac ? <Command className="w-3 h-3" /> : <span className="text-xs">Ctrl</span>}
        <span>+ Enter</span>
      </TooltipContent>
    </Tooltip>
  );
}

function DashboardInputCard() {
  const [taskText, setTaskText] = useState("");
  return (
    <div className="relative bg-white dark:bg-neutral-700/50 border border-neutral-500/15 dark:border-neutral-500/15 rounded-2xl">
      <div className="relative">
        <textarea
          value={taskText}
          onChange={(event) => setTaskText(event.target.value)}
          rows={1}
          placeholder="Describe a task"
          className={clsx(
            "w-full resize-none bg-transparent text-[15px] text-neutral-900 dark:text-neutral-100",
            "placeholder:text-neutral-400 dark:placeholder:text-neutral-500",
            "outline-none border-none focus:outline-none focus:ring-0",
            "min-h-[60px] pt-[14px] pl-[14px] pr-4"
          )}
          aria-label="Describe a task"
        />
      </div>
      <div className="flex items-end justify-between p-2 gap-1">
        <DashboardInputControlsMock />
        <StartTaskButton />
      </div>
    </div>
  );
}

function DashboardTasks({ categories }: { categories: TaskCategory[] }) {
  return (
    <div className="mt-6 w-full">
      <TaskTabs active="tasks" />
      <div className="flex flex-col gap-1 w-full">
        {categories.map((category) => (
          <TaskCategorySection key={category.title} category={category} />
        ))}
      </div>
    </div>
  );
}

function TaskRunDetailRow({
  icon,
  label,
  indentLevel,
  onClick,
}: {
  icon: ReactNode;
  label: string;
  indentLevel: number;
  onClick?: () => void;
}) {
  return (
    <div
      className={clsx(
        "flex items-center justify-between gap-2 px-2 py-1 text-xs rounded-md hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45 cursor-pointer mt-px"
      )}
      style={{ paddingLeft: `${24 + indentLevel * 8}px` }}
      onClick={onClick}
    >
      <span className="flex min-w-0 items-center">
        {icon}
        <span className="text-neutral-600 dark:text-neutral-400">{label}</span>
      </span>
    </div>
  );
}

function DiffView() {
  const diffFiles = [
    { name: "Hero.tsx", additions: 12, deletions: 3 },
    { name: "CTA.tsx", additions: 8, deletions: 1 },
    { name: "Navbar.tsx", additions: 4, deletions: 2 },
  ];

  const diffLines = [
    { type: "context", num: 21, content: "export default function Hero() {" },
    { type: "context", num: 22, content: "  return (" },
    { type: "deletion", num: 23, content: '    <section className="relative min-h-screen bg-neutral-900">' },
    { type: "addition", num: 23, content: '    <section className="relative min-h-screen bg-[#0a0a0a]">' },
    { type: "context", num: 24, content: "      <div className=\"relative z-10 w-full\">" },
    { type: "context", num: 25, content: "        {/* Main headline */}" },
    { type: "deletion", num: 26, content: '        <h1 className="text-3xl mb-6">' },
    { type: "addition", num: 26, content: '        <h1 className="text-3xl md:text-5xl mb-6 tracking-tighter">' },
    { type: "context", num: 27, content: "          Run AI agents" },
    { type: "addition", num: 28, content: '          <span className="text-purple-400">in parallel.</span>' },
    { type: "context", num: 29, content: "        </h1>" },
  ];

  return (
    <div className="flex flex-col h-full">
      {/* Tab bar */}
      <div className="flex items-center gap-1 px-2 py-1.5 border-b border-neutral-200 dark:border-neutral-800 bg-neutral-100 dark:bg-neutral-900/50 text-[11px]">
        <span className="px-2.5 py-1 rounded bg-white dark:bg-neutral-800 text-neutral-900 dark:text-neutral-100 font-medium border border-neutral-200 dark:border-neutral-700">
          Git Diff
        </span>
        <span className="px-2.5 py-1 text-neutral-500 dark:text-neutral-400 hover:bg-neutral-200/50 dark:hover:bg-neutral-800/50 rounded cursor-pointer">Terminal</span>
        <span className="px-2.5 py-1 text-neutral-500 dark:text-neutral-400 hover:bg-neutral-200/50 dark:hover:bg-neutral-800/50 rounded cursor-pointer">Preview</span>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* File list sidebar */}
        <div className="w-[180px] border-r border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-900/30 overflow-y-auto shrink-0">
          <div className="px-2 py-1.5 text-[10px] font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wider">
            Changed Files
          </div>
          {diffFiles.map((file) => (
            <div
              key={file.name}
              className="flex items-center gap-2 px-2 py-1.5 text-[11px] hover:bg-neutral-100 dark:hover:bg-neutral-800/50 cursor-pointer group"
            >
              <GitCompare className="w-3 h-3 text-neutral-400" />
              <span className="text-neutral-700 dark:text-neutral-300 truncate flex-1">{file.name}</span>
              <span className="text-[9px] text-green-600">+{file.additions}</span>
              <span className="text-[9px] text-red-500">-{file.deletions}</span>
            </div>
          ))}
        </div>

        {/* Diff content */}
        <div className="flex-1 overflow-auto bg-white dark:bg-[#0d1117]">
          {/* File header */}
          <div className="sticky top-0 flex items-center gap-2 px-3 py-2 bg-neutral-100 dark:bg-neutral-900 border-b border-neutral-200 dark:border-neutral-800 text-[11px]">
            <span className="text-neutral-600 dark:text-neutral-400">apps/www/components/landing/</span>
            <span className="text-neutral-900 dark:text-neutral-100 font-medium">Hero.tsx</span>
          </div>

          {/* Diff lines */}
          <div className="font-mono text-[11px] leading-[18px]">
            {diffLines.map((line, i) => (
              <div
                key={i}
                className={clsx(
                  "flex",
                  line.type === "addition" && "bg-green-500/10 dark:bg-green-500/15",
                  line.type === "deletion" && "bg-red-500/10 dark:bg-red-500/15"
                )}
              >
                <span className="w-[40px] px-2 text-right text-neutral-400 dark:text-neutral-600 select-none border-r border-neutral-200 dark:border-neutral-800 shrink-0">
                  {line.num}
                </span>
                <span className={clsx(
                  "w-[20px] text-center select-none shrink-0",
                  line.type === "addition" && "text-green-600 dark:text-green-400",
                  line.type === "deletion" && "text-red-500 dark:text-red-400"
                )}>
                  {line.type === "addition" ? "+" : line.type === "deletion" ? "-" : " "}
                </span>
                <span className={clsx(
                  "flex-1 px-2 whitespace-pre",
                  line.type === "addition" && "text-green-700 dark:text-green-300",
                  line.type === "deletion" && "text-red-600 dark:text-red-300",
                  line.type === "context" && "text-neutral-700 dark:text-neutral-300"
                )}>
                  {line.content}
                </span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function VSCodeView() {
  const files = [
    { name: "Hero.tsx", active: true },
    { name: "CTA.tsx", active: false },
    { name: "Navbar.tsx", active: false },
  ];

  const codeLines = [
    { num: 1, content: '"use client";', indent: 0 },
    { num: 2, content: "", indent: 0 },
    { num: 3, content: "import Link from \"next/link\";", indent: 0 },
    { num: 4, content: "import FakeCmuxUI from \"./FakeCmuxUI\";", indent: 0 },
    { num: 5, content: "", indent: 0 },
    { num: 6, content: "export default function Hero() {", indent: 0 },
    { num: 7, content: "return (", indent: 1 },
    { num: 8, content: "<section className=\"relative min-h-screen\">", indent: 2 },
    { num: 9, content: "<div className=\"relative z-10 w-full\">", indent: 3 },
    { num: 10, content: "{/* Main headline */}", indent: 4, comment: true },
    { num: 11, content: "<h1 className=\"text-5xl tracking-tighter\">", indent: 4 },
    { num: 12, content: "Run AI agents", indent: 5 },
    { num: 13, content: "<span className=\"text-purple-400\">", indent: 5 },
    { num: 14, content: "in parallel.", indent: 6 },
    { num: 15, content: "</span>", indent: 5 },
    { num: 16, content: "</h1>", indent: 4 },
  ];

  return (
    <div className="flex flex-col h-full bg-[#1e1e1e]">
      {/* VS Code title bar */}
      <div className="flex items-center h-[30px] bg-[#323233] border-b border-[#252526] px-2">
        <div className="flex items-center gap-1 text-[11px]">
          {files.map((file) => (
            <div
              key={file.name}
              className={clsx(
                "flex items-center gap-1.5 px-3 py-1 rounded-t",
                file.active
                  ? "bg-[#1e1e1e] text-white"
                  : "text-neutral-400 hover:text-neutral-200"
              )}
            >
              <svg className="w-3 h-3 text-[#519aba]" viewBox="0 0 24 24" fill="currentColor">
                <path d="M3 3h18v18H3V3zm16.525 13.707c-.131-.821-.666-1.511-1.334-2.057-.47-.385-.855-.611-.855-.611-.031-.018-.102-.066-.102-.066l-.013-.009c-.063-.039-.186-.12-.186-.12l-.016-.011-.121-.079c-.05-.032-.1-.065-.149-.098-.016-.01-.032-.02-.048-.031-.016-.01-.032-.02-.047-.03-.05-.032-.099-.064-.149-.097l-.017-.011-.178-.119-.071-.046-.107-.071-.023-.015-.145-.097-.027-.018-.072-.048-.051-.034-.02-.013-.073-.049-.051-.034-.02-.013-.073-.049-.144-.097c-1.168-.879-2.044-1.547-2.044-2.635 0-.824.623-1.382 1.5-1.382.616 0 1.044.258 1.363.547l.095.098 1.28-1.314-.057-.061c-.528-.549-1.43-.97-2.68-.97-1.81 0-3.197 1.182-3.197 2.988 0 1.56 1.074 2.517 2.369 3.447.04.028.08.057.12.085.04.028.081.056.121.085l.244.172c.04.028.08.057.12.085.04.029.08.057.12.085l.244.173.121.085.12.085c.04.029.081.057.121.086.04.028.08.056.12.084.04.029.08.057.12.085.04.029.08.057.12.085l.122.087c.04.028.08.056.12.084.04.029.08.057.12.086.04.028.08.056.12.084l.244.173c.281.199.492.443.492.783 0 .49-.48.863-1.163.863-.626 0-1.166-.265-1.564-.716l-.117-.147-1.357 1.267.075.09c.598.717 1.553 1.206 2.863 1.206 1.819 0 3.179-1.083 3.179-2.724 0-.615-.162-1.13-.436-1.544z"/>
              </svg>
              <span>{file.name}</span>
              {file.active && <span className="ml-1 text-neutral-500">×</span>}
            </div>
          ))}
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* File explorer */}
        <div className="w-[160px] bg-[#252526] border-r border-[#1e1e1e] overflow-y-auto shrink-0">
          <div className="px-2 py-1.5 text-[10px] font-medium text-neutral-400 uppercase tracking-wider">
            Explorer
          </div>
          <div className="px-2">
            <div className="flex items-center gap-1 py-0.5 text-[11px] text-neutral-300">
              <ChevronDown className="w-3 h-3" />
              <span>components</span>
            </div>
            <div className="ml-3">
              <div className="flex items-center gap-1 py-0.5 text-[11px] text-neutral-300">
                <ChevronDown className="w-3 h-3" />
                <span>landing</span>
              </div>
              <div className="ml-3">
                {files.map((file) => (
                  <div
                    key={file.name}
                    className={clsx(
                      "flex items-center gap-1 py-0.5 text-[11px] cursor-pointer",
                      file.active ? "text-white bg-[#37373d]" : "text-neutral-400 hover:text-neutral-200"
                    )}
                  >
                    <span className="text-[#519aba]">TS</span>
                    <span>{file.name}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>

        {/* Code editor */}
        <div className="flex-1 overflow-auto font-mono text-[11px] leading-[18px]">
          {codeLines.map((line) => (
            <div key={line.num} className="flex hover:bg-[#2a2d2e]">
              <span className="w-[40px] px-2 text-right text-[#858585] select-none shrink-0">
                {line.num}
              </span>
              <span
                className={clsx(
                  "flex-1 px-2 whitespace-pre",
                  line.comment ? "text-[#6a9955]" : "text-[#d4d4d4]"
                )}
                style={{ paddingLeft: `${8 + line.indent * 16}px` }}
              >
                {line.content}
              </span>
            </div>
          ))}
        </div>
      </div>

      {/* Status bar */}
      <div className="flex items-center h-[22px] bg-[#007acc] px-2 text-[11px] text-white">
        <span className="mr-4">TypeScript React</span>
        <span className="mr-4">UTF-8</span>
        <span>Ln 11, Col 42</span>
      </div>
    </div>
  );
}

function FakeVSCodeWorkspaceView() {
  const files = [
    { name: "Hero.tsx", active: true },
    { name: "page.tsx", active: false },
  ];

  const codeLines = [
    { num: 1, content: '"use client";', indent: 0 },
    { num: 2, content: "", indent: 0 },
    { num: 3, content: 'import Link from "next/link";', indent: 0 },
    { num: 4, content: "", indent: 0 },
    { num: 5, content: "export default function Hero() {", indent: 0 },
    { num: 6, content: "return (", indent: 1 },
    { num: 7, content: '<section className="min-h-screen">', indent: 2 },
    { num: 8, content: '<h1 className="text-5xl">', indent: 3 },
    { num: 9, content: "Run AI agents", indent: 4 },
    { num: 10, content: "</h1>", indent: 3 },
  ];

  const terminalLines = [
    "$ bun run dev",
    "  ▲ Next.js 16.1.1 (Turbopack)",
    "  - Local:   http://localhost:3000",
    "",
    " ✓ Ready in 892ms",
  ];

  return (
    <div className="flex flex-col h-full bg-[#1e1e1e]">
      {/* VS Code title bar */}
      <div className="flex items-center h-[30px] bg-[#323233] border-b border-[#252526] px-2">
        <div className="flex items-center gap-1.5">
          <div className="w-3 h-3 rounded-full bg-[#ff5f57]" />
          <div className="w-3 h-3 rounded-full bg-[#febc2e]" />
          <div className="w-3 h-3 rounded-full bg-[#28c840]" />
        </div>
        <div className="flex-1 flex items-center justify-center text-[11px] text-neutral-400">
          Hero.tsx — /root/workspace
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* File explorer */}
        <div className="w-[120px] bg-[#252526] border-r border-[#1e1e1e] overflow-y-auto shrink-0">
          <div className="px-2 py-1.5 text-[10px] font-medium text-neutral-400 uppercase tracking-wider">
            Explorer
          </div>
          <div className="px-2">
            <div className="flex items-center gap-1 py-0.5 text-[11px] text-neutral-300">
              <ChevronDown className="w-3 h-3" />
              <span>components</span>
            </div>
            <div className="ml-3">
              {files.map((file) => (
                <div
                  key={file.name}
                  className={clsx(
                    "flex items-center gap-1 py-0.5 text-[11px] cursor-pointer",
                    file.active ? "text-white bg-[#37373d]" : "text-neutral-400"
                  )}
                >
                  <span className="text-[#519aba]">TS</span>
                  <span>{file.name}</span>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Main editor area */}
        <div className="flex-1 flex flex-col overflow-hidden">
          {/* Code editor */}
          <div className="flex-1 overflow-auto font-mono text-[11px] leading-[18px]">
            {codeLines.map((line) => (
              <div key={line.num} className="flex hover:bg-[#2a2d2e]">
                <span className="w-[32px] px-2 text-right text-[#858585] select-none shrink-0">
                  {line.num}
                </span>
                <span
                  className="flex-1 px-2 whitespace-pre text-[#d4d4d4]"
                  style={{ paddingLeft: `${8 + line.indent * 12}px` }}
                >
                  {line.content}
                </span>
              </div>
            ))}
          </div>

          {/* Terminal panel */}
          <div className="h-[100px] border-t border-[#252526] bg-[#1e1e1e]">
            <div className="flex items-center h-[24px] bg-[#252526] px-2 text-[10px] text-neutral-400 border-b border-[#1e1e1e]">
              <span className="px-2 py-0.5 bg-[#1e1e1e]">Terminal</span>
            </div>
            <div className="p-2 font-mono text-[10px] leading-[14px] text-neutral-400 overflow-auto">
              {terminalLines.map((line, i) => (
                <div key={i}>{line}</div>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Status bar */}
      <div className="flex items-center h-[22px] bg-[#007acc] px-2 text-[11px] text-white">
        <span className="mr-4">TypeScript React</span>
        <span>Ln 8, Col 12</span>
      </div>
    </div>
  );
}

function FakeVNCBrowserView() {
  return (
    <div className="flex flex-col h-full bg-[#202124]">
      {/* Chrome title bar with tab */}
      <div className="flex items-center h-[36px] bg-[#35363a] px-2">
        <div className="flex items-center gap-1.5 mr-3">
          <div className="w-3 h-3 rounded-full bg-[#ff5f57]" />
          <div className="w-3 h-3 rounded-full bg-[#febc2e]" />
          <div className="w-3 h-3 rounded-full bg-[#28c840]" />
        </div>
        {/* Chrome tab */}
        <div className="flex items-center gap-2 bg-[#202124] rounded-t-lg px-3 py-1.5">
          <svg className="w-4 h-4 shrink-0" viewBox="0 0 24 24">
            <circle cx="12" cy="12" r="10" fill="#4285f4" />
            <circle cx="12" cy="12" r="4" fill="white" />
            <path d="M12 2 L12 8" stroke="#ea4335" strokeWidth="4" />
            <path d="M5.5 17 L9 12" stroke="#fbbc05" strokeWidth="4" />
            <path d="M18.5 17 L15 12" stroke="#34a853" strokeWidth="4" />
          </svg>
          <span className="text-[11px] text-neutral-300">localhost:3000</span>
          <X className="w-3 h-3 text-neutral-500 ml-1" />
        </div>
        <div className="flex-1" />
      </div>

      {/* Chrome URL bar */}
      <div className="flex items-center h-[40px] bg-[#35363a] px-3 gap-3">
        <div className="flex items-center gap-2">
          <ArrowLeft className="w-4 h-4 text-neutral-500" />
          <ArrowRight className="w-4 h-4 text-neutral-500" />
        </div>
        <div className="flex-1 flex items-center bg-[#202124] rounded-full px-4 py-1.5">
          <svg className="w-3.5 h-3.5 text-neutral-500 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
          </svg>
          <span className="text-[13px] text-neutral-300">localhost:3000</span>
        </div>
      </div>

      {/* Page content - cmux website */}
      <div className="flex-1 bg-neutral-950 overflow-hidden">
        {/* Header */}
        <div className="h-14 border-b border-neutral-800 flex items-center px-4 gap-4">
          <div className="flex items-center gap-2">
            <div className="w-7 h-7 bg-purple-500 rounded-md" />
            <span className="text-white font-semibold">cmux</span>
          </div>
          <div className="flex-1" />
          <div className="w-8 h-8 rounded-full bg-neutral-700" />
        </div>

        {/* Content area */}
        <div className="p-6">
          {/* Title and toggle */}
          <div className="flex items-center justify-between mb-6">
            <div className="h-6 w-32 bg-neutral-800 rounded" />
            <div className="w-12 h-6 bg-neutral-700 rounded-full" />
          </div>

          {/* Cards grid */}
          <div className="grid grid-cols-3 gap-4">
            <div className="h-28 bg-neutral-900 rounded-xl border border-neutral-800" />
            <div className="h-28 bg-neutral-900 rounded-xl border border-neutral-800" />
            <div className="h-28 bg-neutral-900 rounded-xl border border-neutral-800" />
          </div>

          {/* Additional content lines */}
          <div className="mt-6 space-y-2">
            <div className="h-4 w-3/4 bg-neutral-800 rounded" />
            <div className="h-4 w-1/2 bg-neutral-800/60 rounded" />
          </div>
        </div>
      </div>
    </div>
  );
}

function PullRequestView() {
  return (
    <div className="flex flex-col h-full px-4 py-3 gap-3">
      <div>
        <div className="text-[11px] text-neutral-500 dark:text-neutral-400 mb-1">Title</div>
        <div className="bg-white dark:bg-neutral-900 rounded-md px-2 py-1.5 text-[12px] text-neutral-900 dark:text-neutral-100 border border-neutral-200 dark:border-neutral-800">
          feat: implement secure auth flow
        </div>
      </div>
      <div>
        <div className="text-[11px] text-neutral-500 dark:text-neutral-400 mb-1">Description</div>
        <div className="bg-white dark:bg-neutral-900 rounded-md px-2 py-1.5 text-[11px] text-neutral-600 dark:text-neutral-300 border border-neutral-200 dark:border-neutral-800 h-16">
          - Migrated to secure_auth()<br />
          - Added comprehensive tests<br />
          - Verified in preview
        </div>
      </div>
      <div className="flex items-center gap-2 text-[11px] text-neutral-500 dark:text-neutral-400">
        <div className="w-3 h-3 bg-green-500 rounded-full flex items-center justify-center">
          <Check className="w-2 h-2 text-white" />
        </div>
        <span>All checks passed</span>
      </div>
      <button
        className="mt-auto flex items-center gap-1.5 px-3 py-1 h-[26px] bg-[#1f883d] text-white rounded hover:bg-[#1f883d]/90 font-medium text-xs select-none whitespace-nowrap"
        type="button"
      >
        Open PR
      </button>
    </div>
  );
}

type HeatmapColors = {
  line: { start: string; end: string };
  token: { start: string; end: string };
};

const createDefaultHeatmapColors = (): HeatmapColors => ({
  line: { start: "#fefce8", end: "#f8e1c9" },
  token: { start: "#fde047", end: "#ffa270" },
});

const areHeatmapColorsEqual = (a: HeatmapColors, b: HeatmapColors): boolean =>
  a.line.start === b.line.start &&
  a.line.end === b.line.end &&
  a.token.start === b.token.start &&
  a.token.end === b.token.end;

function StepBadge({ step, done }: { step: number; done: boolean }) {
  return (
    <span
      className={clsx(
        "flex h-5 w-5 items-center justify-center rounded-full border text-[11px]",
        done
          ? "border-emerald-500 bg-emerald-50 text-emerald-700 dark:border-emerald-400/70 dark:bg-emerald-900/40 dark:text-emerald-100"
          : "border-neutral-300 text-neutral-600 dark:border-neutral-700 dark:text-neutral-400"
      )}
    >
      {done ? <Check className="h-3 w-3" /> : step}
    </span>
  );
}

function EnvironmentsView() {
  const [step, setStep] = useState<EnvironmentFlowStep>("list");
  const [envList, setEnvList] = useState<EnvironmentCard[]>(environments);
  const [selectedRepos, setSelectedRepos] = useState<string[]>([]);
  const [search, setSearch] = useState("");
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [selectedPresetId, setSelectedPresetId] = useState(
    environmentMachinePresets[0]?.id ?? "4vcpu_16gb_48gb"
  );
  const [envName, setEnvName] = useState("");
  const [maintenanceScript, setMaintenanceScript] = useState(
    "(cd cmux && bun i)"
  );
  const [devScript, setDevScript] = useState("(cd cmux && bun run dev)");
  const [envVars, setEnvVars] = useState<EnvironmentEnvVar[]>([
    { name: "DATABASE_URL", value: "postgres://user:pass@host/db", isSecret: true },
    { name: "NEXT_PUBLIC_API_URL", value: "https://api.cmux.dev", isSecret: false },
    { name: "", value: "", isSecret: true },
  ]);
  const [areEnvValuesHidden, setAreEnvValuesHidden] = useState(true);
  const [activeEnvValueIndex, setActiveEnvValueIndex] = useState<number | null>(null);
  const [currentConfigStep, setCurrentConfigStep] = useState<
    "run-scripts" | "browser-setup"
  >("run-scripts");

  const selectedSet = useMemo(() => new Set(selectedRepos), [selectedRepos]);
  const filteredRepos = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return environmentRepoOptions;
    return environmentRepoOptions.filter((repo) =>
      repo.fullName.toLowerCase().includes(q)
    );
  }, [search]);

  const resetDraft = () => {
    setSelectedRepos([]);
    setSearch("");
    setAdvancedOpen(false);
    setSelectedPresetId(environmentMachinePresets[0]?.id ?? "4vcpu_16gb_48gb");
    setEnvName("");
    setMaintenanceScript("(cd cmux && bun i)");
    setDevScript("(cd cmux && bun run dev)");
    setEnvVars([
      { name: "DATABASE_URL", value: "postgres://user:pass@host/db", isSecret: true },
      { name: "NEXT_PUBLIC_API_URL", value: "https://api.cmux.dev", isSecret: false },
      { name: "", value: "", isSecret: true },
    ]);
    setAreEnvValuesHidden(true);
    setActiveEnvValueIndex(null);
    setCurrentConfigStep("run-scripts");
  };

  const toggleRepo = (repo: string) => {
    setSelectedRepos((prev) =>
      prev.includes(repo) ? prev.filter((r) => r !== repo) : [...prev, repo]
    );
  };

  const updateEnvVars = (updater: (prev: EnvironmentEnvVar[]) => EnvironmentEnvVar[]) => {
    setEnvVars((prev) => {
      const next = updater(prev);
      return next.length > 0 ? next : [{ name: "", value: "", isSecret: true }];
    });
  };

  const handleSaveEnvironment = () => {
    const name =
      envName.trim() ||
      selectedRepos[0]?.split("/")[1] ||
      "New environment";
    setEnvList((prev) => [
      ...prev,
      {
        name,
        description: "Custom environment built in the mock flow.",
        selectedRepos: selectedRepos.length ? selectedRepos : ["cmux/devbox-v1"],
        createdAt: "just now",
        snapshotId: "morphvm_new",
      },
    ]);
    setStep("list");
    resetDraft();
  };

  if (step === "list") {
    return (
      <div className="flex flex-col h-full overflow-auto">
        <div className="p-6">
          <div className="flex justify-between items-center mb-6">
            <h2 className="text-lg font-semibold text-neutral-900 dark:text-neutral-100">
              Your Environments
            </h2>
            <button
              type="button"
              onClick={() => setStep("select")}
              className="inline-flex items-center gap-2 rounded-md bg-neutral-900 text-white px-4 py-2 text-sm font-medium hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200 transition-colors"
            >
              <Plus className="w-4 h-4" />
              New Environment
            </button>
          </div>
          <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
            {envList.map((env) => (
              <div
                key={`${env.name}-${env.snapshotId}`}
                className="group relative rounded-lg border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 p-4 hover:shadow-md transition-shadow flex flex-col"
              >
                <div className="flex flex-col grow">
                  <div className="flex items-start justify-between mb-3">
                    <div className="flex items-center gap-2">
                      <Server className="w-5 h-5 text-neutral-600 dark:text-neutral-400" />
                      <h3 className="font-medium text-neutral-900 dark:text-neutral-100">
                        {env.name}
                      </h3>
                    </div>
                  </div>

                  {env.description ? (
                    <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-3 line-clamp-2">
                      {env.description}
                    </p>
                  ) : null}

                  {env.selectedRepos.length > 0 ? (
                    <div className="mb-3">
                      <div className="flex items-center gap-1 text-xs text-neutral-500 dark:text-neutral-500 mb-1">
                        <GitBranch className="w-3 h-3" />
                        Repositories
                      </div>
                      <div className="flex flex-wrap gap-1">
                        {env.selectedRepos.slice(0, 3).map((repo) => (
                          <span
                            key={repo}
                            className="inline-flex items-center rounded-full bg-neutral-100 dark:bg-neutral-900 px-2 py-0.5 text-xs text-neutral-700 dark:text-neutral-300"
                          >
                            {repo.split("/")[1] ?? repo}
                          </span>
                        ))}
                        {env.selectedRepos.length > 3 ? (
                          <span className="inline-flex items-center rounded-full bg-neutral-100 dark:bg-neutral-900 px-2 py-0.5 text-xs text-neutral-700 dark:text-neutral-300">
                            +{env.selectedRepos.length - 3}
                          </span>
                        ) : null}
                      </div>
                    </div>
                  ) : null}

                  <div className="flex items-center gap-3 text-xs text-neutral-500 dark:text-neutral-500">
                    <div className="flex items-center gap-1">
                      <Calendar className="w-3 h-3" />
                      {env.createdAt}
                    </div>
                  </div>
                </div>

                <div className="mt-3 pt-3 border-t border-neutral-100 dark:border-neutral-900">
                  <div className="text-xs text-neutral-500 dark:text-neutral-500 mb-3">
                    Snapshot ID: {env.snapshotId}
                  </div>
                  <div className="flex gap-2">
                    <button
                      type="button"
                      className="flex-1 inline-flex items-center justify-center gap-1.5 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-1.5 text-sm font-medium text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-900 transition-colors"
                    >
                      <Eye className="w-4 h-4" />
                      View
                    </button>
                    <button
                      type="button"
                      className="flex-1 inline-flex items-center justify-center gap-1.5 rounded-md bg-neutral-900 text-white px-3 py-1.5 text-sm font-medium hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200 transition-colors"
                    >
                      <Play className="w-4 h-4" />
                      Launch
                    </button>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    );
  }

  if (step === "select") {
    return (
      <div className="flex flex-col grow select-none relative h-full overflow-hidden">
        <div className="p-6 max-w-3xl w-full mx-auto overflow-auto">
          <div className="mb-4">
            <button
              type="button"
              onClick={() => {
                setStep("list");
                resetDraft();
              }}
              className="inline-flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100 transition-colors"
            >
              <ArrowLeft className="w-4 h-4" />
              Back to environments
            </button>
          </div>
          <h1 className="text-xl font-semibold text-neutral-900 dark:text-neutral-100">
            Select Repositories
          </h1>
          <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
            Choose repositories to include in your environment.
          </p>

          <div className="space-y-6 mt-6">
            <div className="space-y-2">
              <label className="block text-sm font-medium text-neutral-800 dark:text-neutral-200">
                Repositories
              </label>
              <div className="relative">
                <input
                  type="text"
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                  placeholder="Search repositories or paste a GitHub URL..."
                  className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 pr-8 h-9 text-sm text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
                />
              </div>

              <div className="mt-2 rounded-md border border-neutral-200 dark:border-neutral-800 overflow-hidden">
                <div className="max-h-[180px] overflow-y-auto">
                  {filteredRepos.length > 0 ? (
                    <div className="divide-y divide-neutral-200 dark:divide-neutral-900">
                      {filteredRepos.map((repo) => {
                        const isSelected = selectedSet.has(repo.fullName);
                        return (
                          <div
                            key={repo.fullName}
                            role="option"
                            aria-selected={isSelected}
                            onClick={() => toggleRepo(repo.fullName)}
                            onKeyDown={(event) => {
                              if (event.key === "Enter" || event.key === " ") {
                                event.preventDefault();
                                toggleRepo(repo.fullName);
                              }
                            }}
                            tabIndex={0}
                            className="px-3 h-9 flex items-center justify-between bg-white dark:bg-neutral-950 cursor-default select-none outline-none"
                          >
                            <div className="text-sm flex items-center gap-2 min-w-0 flex-1">
                              <div
                                className={clsx(
                                  "mr-1 h-4 w-4 rounded-sm border grid place-items-center shrink-0",
                                  isSelected
                                    ? "border-neutral-700 bg-neutral-800"
                                    : "border-neutral-300 dark:border-neutral-700 bg-white dark:bg-neutral-950"
                                )}
                              >
                                <Check
                                  className={clsx(
                                    "w-3 h-3 text-white transition-opacity",
                                    isSelected ? "opacity-100" : "opacity-0"
                                  )}
                                />
                              </div>
                              <GitHubIcon className="h-4 w-4 shrink-0 text-neutral-700 dark:text-neutral-200" />
                              <span className="truncate">{repo.fullName}</span>
                            </div>
                            <span className="ml-3 text-[10px] text-neutral-500 dark:text-neutral-500">
                              {repo.updated}
                            </span>
                          </div>
                        );
                      })}
                    </div>
                  ) : (
                    <div className="px-3 py-6 text-sm text-neutral-500 dark:text-neutral-400 bg-white dark:bg-neutral-950 text-center">
                      No repositories match your search.
                    </div>
                  )}
                </div>

                <button
                  type="button"
                  className="w-full px-3 py-2 flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 hover:bg-neutral-50 dark:hover:bg-neutral-900 border-t border-neutral-200 dark:border-neutral-800 transition-colors"
                >
                  <GitHubIcon className="h-3.5 w-3.5" />
                  <span>Connect another GitHub account</span>
                </button>
              </div>
            </div>

            {selectedRepos.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                {selectedRepos.map((fullName) => (
                  <span
                    key={fullName}
                    className="inline-flex items-center gap-1 rounded-full border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 px-2 py-1 text-xs"
                  >
                    <button
                      type="button"
                      aria-label={`Remove ${fullName}`}
                      onClick={() => toggleRepo(fullName)}
                      className="-ml-1 inline-flex h-4 w-4 items-center justify-center rounded-full hover:bg-neutral-100 dark:hover:bg-neutral-900"
                    >
                      <X className="h-3 w-3" />
                    </button>
                    <GitHubIcon className="h-3 w-3 shrink-0 text-neutral-700 dark:text-neutral-300" />
                    {fullName}
                  </span>
                ))}
              </div>
            ) : null}

            <div className="rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 overflow-hidden">
              <details
                className="group"
                open={advancedOpen}
                onToggle={(event) => setAdvancedOpen(event.currentTarget.open)}
              >
                <summary className="text-sm cursor-pointer py-2 px-3 transition-colors hover:bg-neutral-50 dark:hover:bg-neutral-900 rounded-none list-none">
                  Advanced options
                </summary>
                <div className="pt-0 px-3 pb-3 border-t border-neutral-200 dark:border-neutral-800">
                  <div className="space-y-4 pt-1.5">
                    <div className="text-sm font-medium text-neutral-800 dark:text-neutral-200">
                      Machine size
                    </div>
                    <div className="grid gap-3 sm:grid-cols-2 pt-1.5">
                      {environmentMachinePresets.map((preset) => {
                        const isSelected = preset.id === selectedPresetId;
                        return (
                          <button
                            key={preset.id}
                            type="button"
                            onClick={() => setSelectedPresetId(preset.id)}
                            className={clsx(
                              "relative flex h-full cursor-pointer flex-col justify-between rounded-lg border px-4 py-3 text-left transition-colors focus:outline-none",
                              isSelected
                                ? "border-neutral-900 dark:border-neutral-100 bg-neutral-50 dark:bg-neutral-900"
                                : "border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 hover:border-neutral-300 dark:hover:border-neutral-700"
                            )}
                          >
                            <div className="flex h-full flex-col gap-3">
                              <div className="flex items-start justify-between gap-3">
                                <div>
                                  <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                                    {preset.label}
                                  </p>
                                  <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-neutral-500 dark:text-neutral-400">
                                    <span>{preset.cpu}</span>
                                    <span>{preset.memory}</span>
                                    <span>{preset.disk}</span>
                                  </div>
                                </div>
                                <span
                                  className={clsx(
                                    "mt-1 inline-flex h-5 w-5 items-center justify-center rounded-full border",
                                    isSelected
                                      ? "border-neutral-900 dark:border-neutral-100 bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                                      : "border-neutral-300 dark:border-neutral-700 bg-white text-transparent dark:bg-neutral-950"
                                  )}
                                >
                                  <Check className="h-3 w-3" aria-hidden="true" />
                                </span>
                              </div>
                              <p className="text-xs text-neutral-500 dark:text-neutral-400">
                                {preset.description}
                              </p>
                            </div>
                          </button>
                        );
                      })}
                    </div>
                  </div>
                </div>
              </details>
            </div>

            <div className="flex items-center gap-3 pt-2">
              <button
                type="button"
                onClick={() => setStep("configure")}
                className="inline-flex items-center gap-2 rounded-md bg-neutral-900 text-white px-3 py-2 text-sm hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
              >
                Continue
              </button>
              <button
                type="button"
                onClick={() => setStep("configure")}
                className="inline-flex items-center gap-2 rounded-md border border-neutral-200 dark:border-neutral-800 px-3 py-2 text-sm text-neutral-800 dark:text-neutral-200 hover:bg-neutral-50 dark:hover:bg-neutral-900"
              >
                Configure manually
              </button>
            </div>
            <p className="text-xs text-neutral-500 dark:text-neutral-500">
              You can also manually configure an environment from a bare VM. We'll
              capture your changes as a reusable base snapshot.
            </p>
          </div>
        </div>
      </div>
    );
  }

  if (step === "configure") {
    const placeholderName =
      selectedRepos[0]?.split("/").pop() ?? "environment";
    return (
      <div className="flex flex-col grow select-none relative h-full overflow-hidden">
        <div className="p-6 max-w-3xl w-full mx-auto overflow-auto">
          <div className="mb-4">
            <button
              type="button"
              onClick={() => setStep("select")}
              className="inline-flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100 transition-colors"
            >
              <ArrowLeft className="w-4 h-4" />
              Back to repository selection
            </button>
          </div>
          <h1 className="text-xl font-semibold text-neutral-900 dark:text-neutral-100">
            Configure workspace
          </h1>
          {selectedRepos.length > 0 ? (
            <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
              {selectedRepos.map((repo, index) => (
                <span key={repo} className="inline-flex items-center gap-1.5">
                  {index > 0 && ", "}
                  <GitHubIcon className="h-3.5 w-3.5 shrink-0 inline" />
                  <span>{repo}</span>
                </span>
              ))}
            </p>
          ) : null}

          <div className="space-y-6 mt-6">
            <div>
              <label className="block text-sm font-medium text-neutral-900 dark:text-neutral-100 mb-2">
                Environment Name
              </label>
              <input
                type="text"
                value={envName}
                onChange={(event) => setEnvName(event.target.value)}
                placeholder={`${placeholderName}-${new Date().toISOString().slice(0, 10)}`}
                className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2.5 text-sm text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
              />
              <p className="mt-2 text-xs text-neutral-500 dark:text-neutral-400">
                A unique name for this environment configuration
              </p>
            </div>

            <details className="group" open>
              <summary className="flex items-center gap-2 cursor-pointer font-semibold text-neutral-900 dark:text-neutral-100 list-none text-base">
                <ChevronDown className="h-4 w-4 text-neutral-400 transition-transform" />
                Maintenance and Dev Scripts
              </summary>
              <div className="mt-4 pl-6 space-y-4">
                <p className="text-xs text-neutral-500 dark:text-neutral-400">
                  Scripts run from{" "}
                  <code className="font-mono text-neutral-600 dark:text-neutral-300">
                    /root/workspace
                  </code>{" "}
                  which contains your repository as subdirectory.
                </p>

                <div>
                  <label className="block text-xs text-neutral-500 dark:text-neutral-400 mb-1.5">
                    Maintenance Script
                  </label>
                  <textarea
                    value={maintenanceScript}
                    onChange={(event) => setMaintenanceScript(event.target.value)}
                    placeholder="(cd [repo] && bun i)"
                    rows={2}
                    className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-xs font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-none"
                  />
                  <p className="text-xs text-neutral-400 mt-1">
                    Runs after git pull to install dependencies
                  </p>
                </div>
                <div>
                  <label className="block text-xs text-neutral-500 dark:text-neutral-400 mb-1.5">
                    Dev Script
                  </label>
                  <textarea
                    value={devScript}
                    onChange={(event) => setDevScript(event.target.value)}
                    placeholder="(cd [repo] && bun run dev)"
                    rows={2}
                    className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-xs font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-none"
                  />
                  <p className="text-xs text-neutral-400 mt-1">
                    Starts the development server
                  </p>
                </div>
              </div>
            </details>

            <details className="group" open>
              <summary className="flex items-center gap-2 cursor-pointer font-semibold text-neutral-900 dark:text-neutral-100 list-none text-base">
                <ChevronDown className="h-4 w-4 text-neutral-400 transition-transform" />
                <span>Environment Variables</span>
                <div className="ml-auto flex items-center gap-2">
                  <button
                    type="button"
                    onClick={(event) => {
                      event.preventDefault();
                      setAreEnvValuesHidden((prev) => !prev);
                    }}
                    className="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 transition p-0.5"
                    aria-label={areEnvValuesHidden ? "Reveal values" : "Hide values"}
                  >
                    {areEnvValuesHidden ? (
                      <EyeOff className="h-4 w-4" />
                    ) : (
                      <Eye className="h-4 w-4" />
                    )}
                  </button>
                </div>
              </summary>
              <div className="mt-4 pl-6 space-y-2">
                <div
                  className="grid gap-2 text-xs text-neutral-500 items-center mb-1"
                  style={{
                    gridTemplateColumns: "minmax(0, 1fr) minmax(0, 1.5fr) 40px",
                  }}
                >
                  <span>Name</span>
                  <span>Value</span>
                  <span />
                </div>
                {envVars.map((row, idx) => {
                  const isEditingValue = activeEnvValueIndex === idx;
                  const shouldMaskValue =
                    areEnvValuesHidden &&
                    row.value.trim().length > 0 &&
                    !isEditingValue;
                  return (
                    <div
                      key={`${row.name}-${idx}`}
                      className="grid gap-2 items-center min-h-9"
                      style={{
                        gridTemplateColumns:
                          "minmax(0, 1fr) minmax(0, 1.5fr) 40px",
                      }}
                    >
                      <input
                        type="text"
                        value={row.name}
                        onChange={(event) => {
                          const nextName = event.target.value;
                          updateEnvVars((prev) => {
                            const next = [...prev];
                            if (next[idx]) {
                              next[idx] = { ...next[idx], name: nextName };
                            }
                            return next;
                          });
                        }}
                        placeholder="EXAMPLE_NAME"
                        className="w-full min-w-0 h-9 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
                      />
                      <input
                        type={shouldMaskValue ? "password" : "text"}
                        value={shouldMaskValue ? MASKED_ENV_VALUE : row.value}
                        onChange={
                          shouldMaskValue
                            ? undefined
                            : (event) => {
                                const nextValue = event.target.value;
                                updateEnvVars((prev) => {
                                  const next = [...prev];
                                  if (next[idx]) {
                                    next[idx] = {
                                      ...next[idx],
                                      value: nextValue,
                                    };
                                  }
                                  return next;
                                });
                              }
                        }
                        onFocus={() => setActiveEnvValueIndex(idx)}
                        onBlur={() =>
                          setActiveEnvValueIndex(
                            activeEnvValueIndex === idx ? null : activeEnvValueIndex
                          )
                        }
                        readOnly={shouldMaskValue}
                        placeholder="I9JU23NF394R6HH"
                        className="w-full min-w-0 h-9 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
                      />
                      <button
                        type="button"
                        disabled={envVars.length <= 1}
                        onClick={() =>
                          updateEnvVars((prev) => prev.filter((_, i) => i !== idx))
                        }
                        className={clsx(
                          "h-9 w-9 rounded-md border border-neutral-200 dark:border-neutral-800 text-neutral-500 dark:text-neutral-400 grid place-items-center",
                          envVars.length <= 1
                            ? "opacity-60 cursor-not-allowed"
                            : "hover:bg-neutral-50 dark:hover:bg-neutral-900"
                        )}
                        aria-label="Remove variable"
                      >
                        <Minus className="w-4 h-4" />
                      </button>
                    </div>
                  );
                })}
                <div className="mt-1">
                  <button
                    type="button"
                    onClick={() =>
                      updateEnvVars((prev) => [
                        ...prev,
                        { name: "", value: "", isSecret: true },
                      ])
                    }
                    className="inline-flex items-center gap-2 h-9 rounded-md border border-neutral-200 dark:border-neutral-800 px-3 text-sm text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-900 transition"
                  >
                    <Plus className="w-4 h-4" /> Add variable
                  </button>
                </div>
              </div>
              <p className="text-xs text-neutral-400 mt-4 pl-6">
                Tip: Paste a .env file to auto-fill
              </p>
            </details>
          </div>

          <div className="flex items-center gap-3 pt-6">
            <button
              type="button"
              onClick={() => setStep("workspace")}
              className="inline-flex items-center gap-2 rounded-md bg-neutral-900 text-white px-3 py-2 text-sm hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
            >
              Continue
              <ArrowRight className="w-4 h-4" />
            </button>
          </div>
        </div>
      </div>
    );
  }

  const runScriptsDone = currentConfigStep === "browser-setup";

  return (
    <div className="flex h-full overflow-hidden font-sans text-[15px] leading-6">
      <div
        className="h-full flex flex-col overflow-hidden bg-white dark:bg-neutral-900 relative shrink-0"
        style={{ width: 420 }}
      >
        <div className="flex-shrink-0 px-5 pt-4 pb-2">
          <button
            type="button"
            onClick={() => setStep("configure")}
            className="inline-flex items-center gap-1 text-[11px] text-neutral-500 dark:text-neutral-400 mb-3 hover:text-neutral-900 dark:hover:text-neutral-100"
          >
            <ArrowLeft className="h-3 w-3" />
            Back to project setup
          </button>
          <h1 className="text-base font-semibold text-neutral-900 dark:text-neutral-100 tracking-tight">
            Configure workspace
          </h1>
          {selectedRepos.length > 0 ? (
            <div className="flex flex-wrap items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 pt-1">
              {selectedRepos.map((repo) => (
                <span key={repo} className="inline-flex items-center gap-1.5">
                  <GitHubIcon className="h-4 w-4 shrink-0" />
                  <span className="font-sans text-xs">{repo}</span>
                </span>
              ))}
            </div>
          ) : null}
          <p className="text-[11px] text-neutral-500 dark:text-neutral-400 leading-relaxed pt-3">
            Your workspace root at{" "}
            <code className="px-1 py-0.5 rounded bg-neutral-100 dark:bg-neutral-800 text-[10px] text-neutral-700 dark:text-neutral-300">
              /root/workspace
            </code>{" "}
            contains your repositories as subdirectories.
          </p>
        </div>

        <div className="flex-1 overflow-y-auto px-5 pb-5 space-y-4">
          <details className="group" open={false}>
            <summary className="flex items-center gap-2 list-none cursor-pointer">
              <ChevronDown className="h-3.5 w-3.5 text-neutral-400 transition-transform -rotate-90 group-open:rotate-0" />
              <StepBadge step={1} done />
              <span className="text-[13px] font-medium text-neutral-900 dark:text-neutral-100">
                Maintenance and Dev Scripts
              </span>
            </summary>
            <div className="mt-3 ml-6 space-y-2 text-[11px] text-neutral-500 dark:text-neutral-400">
              <p>Scripts configured in the previous step.</p>
            </div>
          </details>

          <details className="group" open={false}>
            <summary className="flex items-center gap-2 list-none cursor-pointer">
              <ChevronDown className="h-3.5 w-3.5 text-neutral-400 transition-transform -rotate-90 group-open:rotate-0" />
              <StepBadge step={2} done />
              <span className="text-[13px] font-medium text-neutral-900 dark:text-neutral-100">
                Environment Variables
              </span>
            </summary>
            <div className="mt-3 ml-6 space-y-2 text-[11px] text-neutral-500 dark:text-neutral-400">
              <p>Environment variables configured in the previous step.</p>
            </div>
          </details>

          <div>
            <details className="group" open={currentConfigStep === "run-scripts"}>
              <summary className="flex items-center gap-2 list-none cursor-pointer">
                <ChevronDown className="h-3.5 w-3.5 text-neutral-400 transition-transform -rotate-90 group-open:rotate-0" />
                <StepBadge step={3} done={runScriptsDone} />
                <span className="text-[13px] font-medium text-neutral-900 dark:text-neutral-100">
                  Run scripts in VS Code terminal
                </span>
              </summary>
              <div className="mt-3 ml-6 space-y-3">
                <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                  Setup VS Code development environment. Open terminal and paste:
                </p>
                <div className="rounded-md border border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-900 overflow-hidden">
                  <div className="flex items-center justify-between px-3 py-1.5 border-b border-neutral-200 dark:border-neutral-800 bg-neutral-100 dark:bg-neutral-800/50">
                    <span className="text-[10px] uppercase tracking-wide text-neutral-500">
                      Commands
                    </span>
                    <button
                      type="button"
                      className="p-0.5 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
                    >
                      <Copy className="h-3 w-3" />
                    </button>
                  </div>
                  <pre className="px-3 py-2 text-[11px] font-mono text-neutral-900 dark:text-neutral-100 overflow-x-auto whitespace-pre-wrap break-all select-all">
                    {[maintenanceScript.trim(), devScript.trim()]
                      .filter(Boolean)
                      .join(" && ")}
                  </pre>
                </div>
                <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                  Proceed once dev script is running.
                </p>
              </div>
            </details>
            {currentConfigStep === "run-scripts" ? (
              <button
                type="button"
                onClick={() => setCurrentConfigStep("browser-setup")}
                className="w-full mt-4 inline-flex items-center justify-center gap-2 rounded-md bg-neutral-900 dark:bg-neutral-100 text-white dark:text-neutral-900 px-4 py-2 text-sm font-semibold hover:bg-neutral-800 dark:hover:bg-neutral-200 transition cursor-pointer"
              >
                Continue
                <ArrowRight className="w-4 h-4" />
              </button>
            ) : null}
          </div>

          <div>
            <details className="group" open={currentConfigStep === "browser-setup"}>
              <summary className="flex items-center gap-2 list-none cursor-pointer">
                <ChevronDown className="h-3.5 w-3.5 text-neutral-400 transition-transform -rotate-90 group-open:rotate-0" />
                <StepBadge step={4} done={false} />
                <span className="text-[13px] font-medium text-neutral-900 dark:text-neutral-100">
                  Configure browser
                </span>
              </summary>
              <div className="mt-3 ml-6 space-y-3">
                <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                  Use the browser on the right to set up authentication:
                </p>
                <ul className="space-y-2 text-[11px] text-neutral-600 dark:text-neutral-400">
                  <li className="flex items-start gap-2">
                    <span className="flex h-4 w-4 items-center justify-center rounded-full bg-neutral-100 dark:bg-neutral-800 text-[10px] text-neutral-500 dark:text-neutral-400 flex-shrink-0 mt-0.5">
                      1
                    </span>
                    <span>Sign in to any dashboards or SaaS tools</span>
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="flex h-4 w-4 items-center justify-center rounded-full bg-neutral-100 dark:bg-neutral-800 text-[10px] text-neutral-500 dark:text-neutral-400 flex-shrink-0 mt-0.5">
                      2
                    </span>
                    <span>Dismiss cookie banners, popups, or MFA prompts</span>
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="flex h-4 w-4 items-center justify-center rounded-full bg-neutral-100 dark:bg-neutral-800 text-[10px] text-neutral-500 dark:text-neutral-400 flex-shrink-0 mt-0.5">
                      3
                    </span>
                    <span>Navigate to your dev server URL (e.g., localhost:3000)</span>
                  </li>
                </ul>
                <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                  Proceed once browser is set up properly.
                </p>
              </div>
            </details>
            {currentConfigStep === "browser-setup" ? (
              <button
                type="button"
                onClick={handleSaveEnvironment}
                className="w-full mt-4 inline-flex items-center justify-center rounded-md bg-neutral-900 dark:bg-neutral-100 text-white dark:text-neutral-900 px-4 py-2 text-sm font-semibold hover:bg-neutral-800 dark:hover:bg-neutral-200 transition"
              >
                Save configuration
              </button>
            ) : null}
          </div>
        </div>
      </div>

      <div className="flex-1 flex flex-col bg-neutral-950 overflow-hidden">
        {currentConfigStep === "browser-setup" ? (
          <FakeVNCBrowserView />
        ) : (
          <FakeVSCodeWorkspaceView />
        )}
      </div>
    </div>
  );
}

function SettingsSwitch({
  checked,
  onChange,
  ariaLabel,
  disabled = false,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  ariaLabel: string;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-label={ariaLabel}
      aria-checked={checked}
      onClick={() => {
        if (disabled) return;
        onChange(!checked);
      }}
      className={clsx(
        "relative inline-flex h-6 w-10 items-center rounded-full border px-1 transition-colors",
        checked
          ? "bg-blue-500 border-blue-500"
          : "bg-neutral-200/70 dark:bg-neutral-800/80 border-neutral-200 dark:border-neutral-700",
        disabled && "opacity-60 cursor-not-allowed"
      )}
      disabled={disabled}
    >
      <span
        className={clsx(
          "h-4 w-4 rounded-full bg-white shadow-sm transition-transform",
          checked ? "translate-x-4" : "translate-x-0"
        )}
      />
    </button>
  );
}

function SettingsView() {
  const initialTeamName = "Manaflow";
  const initialTeamSlug = "manaflow";
  const initialWorktreePath = "";
  const initialAutoPrEnabled = true;
  const initialHeatmapModel = "anthropic-opus-4-5";
  const initialHeatmapLanguage = "en";
  const initialHeatmapThreshold = 0;

  const initialHeatmapColors = useMemo(() => createDefaultHeatmapColors(), []);
  const initialApiKeyValues = useMemo(
    () => ({ ...DEFAULT_API_KEY_VALUES, ...MOCK_API_KEY_PREFILL }),
    []
  );
  const initialContainerSettings = useMemo(
    () => ({
      maxRunningContainers: 5,
      reviewPeriodMinutes: 60,
      autoCleanupEnabled: true,
      stopImmediatelyOnCompletion: false,
      minContainersToKeep: 0,
    }),
    []
  );

  const [teamName, setTeamName] = useState(initialTeamName);
  const [teamSlug, setTeamSlug] = useState(initialTeamSlug);
  const [theme, setTheme] = useState<"light" | "dark" | "system">("system");
  const [autoPrEnabled, setAutoPrEnabled] = useState(initialAutoPrEnabled);
  const [heatmapModel, setHeatmapModel] = useState(initialHeatmapModel);
  const [heatmapLanguage, setHeatmapLanguage] = useState(initialHeatmapLanguage);
  const [heatmapThreshold, setHeatmapThreshold] = useState(initialHeatmapThreshold);
  const [heatmapColors, setHeatmapColors] = useState<HeatmapColors>(initialHeatmapColors);
  const [worktreePath, setWorktreePath] = useState(initialWorktreePath);
  const [apiKeyValues, setApiKeyValues] = useState<Record<string, string>>(initialApiKeyValues);
  const [showKeys, setShowKeys] = useState<Record<string, boolean>>({});
  const [expandedUsedList, setExpandedUsedList] = useState<Record<string, boolean>>({});
  const [containerSettings, setContainerSettings] = useState(initialContainerSettings);
  const [isSaving, setIsSaving] = useState(false);
  const [isRefreshingStatus, setIsRefreshingStatus] = useState(false);

  const hasChanges =
    teamName.trim() !== initialTeamName ||
    teamSlug.trim() !== initialTeamSlug ||
    autoPrEnabled !== initialAutoPrEnabled ||
    heatmapModel !== initialHeatmapModel ||
    heatmapLanguage !== initialHeatmapLanguage ||
    heatmapThreshold !== initialHeatmapThreshold ||
    worktreePath !== initialWorktreePath ||
    !areHeatmapColorsEqual(heatmapColors, initialHeatmapColors) ||
    MOCK_API_KEYS.some(
      (key) =>
        (apiKeyValues[key.envVar] ?? "") !==
        (initialApiKeyValues[key.envVar] ?? "")
    ) ||
    containerSettings.maxRunningContainers !==
      initialContainerSettings.maxRunningContainers ||
    containerSettings.reviewPeriodMinutes !==
      initialContainerSettings.reviewPeriodMinutes ||
    containerSettings.autoCleanupEnabled !==
      initialContainerSettings.autoCleanupEnabled ||
    containerSettings.stopImmediatelyOnCompletion !==
      initialContainerSettings.stopImmediatelyOnCompletion ||
    containerSettings.minContainersToKeep !==
      initialContainerSettings.minContainersToKeep;

  const handleSave = () => {
    if (!hasChanges || isSaving) return;
    setIsSaving(true);
    window.setTimeout(() => setIsSaving(false), 800);
  };

  const handleApiKeyChange = (envVar: string, value: string) => {
    setApiKeyValues((prev) => ({ ...prev, [envVar]: value }));
  };

  const toggleShowKey = (envVar: string) => {
    setShowKeys((prev) => ({ ...prev, [envVar]: !prev[envVar] }));
  };

  const handleRefreshStatus = () => {
    if (isRefreshingStatus) return;
    setIsRefreshingStatus(true);
    window.setTimeout(() => setIsRefreshingStatus(false), 800);
  };

  const dockerOk = true;
  const gitOk = true;
  const dockerImage = {
    name: "cmux-worker:latest",
    isAvailable: true,
    isPulling: false,
  };

  const providerRows = [
    { name: "Claude Code", isAvailable: false, missing: "ANTHROPIC_API_KEY" },
    { name: "OpenAI", isAvailable: true },
    { name: "Gemini", isAvailable: false, missing: "GEMINI_API_KEY" },
    { name: "Amp", isAvailable: true },
    { name: "Cursor", isAvailable: true },
  ];

  return (
    <div className="flex flex-col grow overflow-auto select-none relative">
      <div className="p-6 max-w-3xl">
        <div className="mb-6">
          <h1 className="text-xl font-semibold text-neutral-900 dark:text-neutral-100">
            Settings
          </h1>
          <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
            Manage your workspace preferences and configuration
          </p>
        </div>

        <div className="space-y-4">
          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Team Name
              </h2>
            </div>
            <div className="p-4">
              <div>
                <label
                  htmlFor="teamName"
                  className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                >
                  Display Name
                </label>
                <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                  How your team is displayed across cmux.
                </p>
                <input
                  type="text"
                  id="teamName"
                  value={teamName}
                  onChange={(event) => setTeamName(event.target.value)}
                  placeholder="Your Team"
                  className="w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 border-neutral-300 dark:border-neutral-700 focus:ring-blue-500"
                />
              </div>
            </div>
            <div className="px-4 py-3 border-t border-neutral-200 dark:border-neutral-800 flex items-center justify-end">
              <button
                type="button"
                className="px-3 py-1.5 text-sm rounded-md bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 disabled:opacity-50"
                disabled={
                  isSaving || teamName.trim() === initialTeamName.trim()
                }
              >
                Save
              </button>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Team URL
              </h2>
            </div>
            <div className="p-4">
              <div>
                <label
                  htmlFor="teamSlug"
                  className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                >
                  URL Slug
                </label>
                <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                  Set the slug used in links, e.g. /your-team/dashboard.
                  Lowercase letters, numbers, and hyphens. 3–48 characters.
                </p>
                <div className="inline-flex items-center w-full rounded-lg bg-white dark:bg-neutral-900 border border-neutral-300 dark:border-neutral-700">
                  <span className="px-3 py-2 text-sm text-neutral-500 dark:text-neutral-400 select-none bg-neutral-50 dark:bg-neutral-800/50 border-r border-neutral-200 dark:border-neutral-700 rounded-l-lg">
                    cmux.dev/
                  </span>
                  <input
                    id="teamSlug"
                    aria-label="Team slug"
                    type="text"
                    value={teamSlug}
                    onChange={(event) => setTeamSlug(event.target.value.toLowerCase())}
                    placeholder="your-team"
                    className="flex-1 bg-transparent border-0 outline-none focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-inset px-3 py-2 text-sm text-neutral-900 dark:text-neutral-100 rounded-r-lg"
                  />
                </div>
              </div>
            </div>
            <div className="px-4 py-3 border-t border-neutral-200 dark:border-neutral-800 flex items-center justify-end">
              <button
                type="button"
                className="px-3 py-1.5 text-sm rounded-md bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 disabled:opacity-50"
                disabled={
                  isSaving || teamSlug.trim() === initialTeamSlug.trim()
                }
              >
                Save
              </button>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Connected Accounts
              </h2>
              <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">
                Connect accounts to enable additional features like private repo access
              </p>
            </div>
            <div className="p-4">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="w-9 h-9 bg-neutral-100 dark:bg-neutral-800 rounded-lg flex items-center justify-center">
                    <GitHubIcon className="w-4.5 h-4.5 text-neutral-700 dark:text-neutral-300" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      GitHub
                    </p>
                    <p className="text-xs text-neutral-500 dark:text-neutral-400">
                      Connected as @manaflow
                    </p>
                  </div>
                </div>
                <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 dark:bg-green-900/30 text-green-800 dark:text-green-400">
                  Connected
                </span>
              </div>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Appearance
              </h2>
            </div>
            <div className="p-4">
              <div>
                <label className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2">
                  Theme
                </label>
                <div className="grid grid-cols-3 gap-2">
                  {(["light", "dark", "system"] as const).map((option) => (
                    <button
                      key={option}
                      type="button"
                      onClick={() => setTheme(option)}
                      className={clsx(
                        "p-2 border-2 rounded-lg text-sm font-medium transition-colors",
                        theme === option
                          ? "border-blue-500 bg-neutral-50 dark:bg-neutral-800 text-neutral-700 dark:text-neutral-300"
                          : "border-neutral-200 dark:border-neutral-700 text-neutral-700 dark:text-neutral-300"
                      )}
                    >
                      {option === "light" ? "Light" : option === "dark" ? "Dark" : "System"}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Getting Started
              </h2>
            </div>
            <div className="p-4">
              <div className="flex items-start justify-between gap-4">
                <div className="flex items-start gap-3">
                  <div className="w-9 h-9 bg-blue-100 dark:bg-blue-900/30 rounded-lg flex items-center justify-center flex-shrink-0">
                    <HelpCircle className="w-4.5 h-4.5 text-blue-600 dark:text-blue-400" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      Product Tour
                    </p>
                    <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">
                      Take a guided tour of cmux to learn about its features and how to get the most out of it.
                    </p>
                  </div>
                </div>
                <button
                  type="button"
                  className="px-3 py-1.5 text-xs font-medium text-white bg-blue-500 hover:bg-blue-600 rounded-md transition-colors flex-shrink-0"
                >
                  Start Tour
                </button>
              </div>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Crown Evaluator
              </h2>
            </div>
            <div className="p-4">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <label className="block text-sm font-medium text-neutral-900 dark:text-neutral-100">
                    Auto-create pull request with the best diff
                  </label>
                  <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
                    After all agents finish, automatically create a pull request with the winning agent's solution.
                  </p>
                </div>
                <SettingsSwitch
                  ariaLabel="Auto-create pull request with the best diff"
                  checked={autoPrEnabled}
                  onChange={setAutoPrEnabled}
                />
              </div>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Diff Heatmap Review
              </h2>
            </div>
            <div className="p-4 space-y-6">
              <div>
                <label
                  htmlFor="heatmapModel"
                  className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                >
                  Review Model
                </label>
                <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                  Select the AI model used to analyze diffs and highlight areas that need attention.
                </p>
                <div className="relative">
                  <select
                    id="heatmapModel"
                    value={heatmapModel}
                    onChange={(event) => setHeatmapModel(event.target.value)}
                    className="w-full appearance-none px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 text-sm"
                  >
                    {HEATMAP_MODEL_OPTIONS.map((option) => (
                      <option key={option.value} value={option.value}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                  <ChevronDown className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-500 dark:text-neutral-400" />
                </div>
              </div>

              <div>
                <label
                  htmlFor="heatmapTooltipLanguage"
                  className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                >
                  Tooltip Language
                </label>
                <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                  Language for the review comments shown in heatmap tooltips.
                </p>
                <div className="relative">
                  <select
                    id="heatmapTooltipLanguage"
                    value={heatmapLanguage}
                    onChange={(event) => setHeatmapLanguage(event.target.value)}
                    className="w-full appearance-none px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 text-sm"
                  >
                    {TOOLTIP_LANGUAGE_OPTIONS.map((option) => (
                      <option key={option.value} value={option.value}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                  <ChevronDown className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-500 dark:text-neutral-400" />
                </div>
              </div>

              <div>
                <label
                  htmlFor="heatmapThreshold"
                  className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                >
                  Visibility Threshold: {Math.round(heatmapThreshold * 100)}%
                </label>
                <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                  Only show highlights for lines with a review score above this threshold.
                </p>
                <input
                  type="range"
                  id="heatmapThreshold"
                  min="0"
                  max="1"
                  step="0.05"
                  value={heatmapThreshold}
                  onChange={(event) =>
                    setHeatmapThreshold(Number.parseFloat(event.target.value))
                  }
                  className="w-full h-2 bg-neutral-200 dark:bg-neutral-700 rounded-lg appearance-none cursor-pointer accent-blue-600"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2">
                  Heatmap Colors
                </label>
                <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                  Customize the gradient colors for line and token highlighting.
                </p>
                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <span className="text-xs font-medium text-neutral-600 dark:text-neutral-400">
                      Line Background
                    </span>
                    <div className="flex items-center gap-2">
                      <label className="text-xs text-neutral-500 dark:text-neutral-400 w-10">Low</label>
                      <input
                        type="color"
                        value={heatmapColors.line.start}
                        onChange={(event) =>
                          setHeatmapColors((prev) => ({
                            ...prev,
                            line: { ...prev.line, start: event.target.value },
                          }))
                        }
                        className="w-8 h-8 rounded border border-neutral-300 dark:border-neutral-600 cursor-pointer"
                      />
                      <span className="text-xs font-mono text-neutral-500">
                        {heatmapColors.line.start}
                      </span>
                    </div>
                    <div className="flex items-center gap-2">
                      <label className="text-xs text-neutral-500 dark:text-neutral-400 w-10">High</label>
                      <input
                        type="color"
                        value={heatmapColors.line.end}
                        onChange={(event) =>
                          setHeatmapColors((prev) => ({
                            ...prev,
                            line: { ...prev.line, end: event.target.value },
                          }))
                        }
                        className="w-8 h-8 rounded border border-neutral-300 dark:border-neutral-600 cursor-pointer"
                      />
                      <span className="text-xs font-mono text-neutral-500">
                        {heatmapColors.line.end}
                      </span>
                    </div>
                  </div>
                  <div className="space-y-2">
                    <span className="text-xs font-medium text-neutral-600 dark:text-neutral-400">
                      Token Highlight
                    </span>
                    <div className="flex items-center gap-2">
                      <label className="text-xs text-neutral-500 dark:text-neutral-400 w-10">Low</label>
                      <input
                        type="color"
                        value={heatmapColors.token.start}
                        onChange={(event) =>
                          setHeatmapColors((prev) => ({
                            ...prev,
                            token: { ...prev.token, start: event.target.value },
                          }))
                        }
                        className="w-8 h-8 rounded border border-neutral-300 dark:border-neutral-600 cursor-pointer"
                      />
                      <span className="text-xs font-mono text-neutral-500">
                        {heatmapColors.token.start}
                      </span>
                    </div>
                    <div className="flex items-center gap-2">
                      <label className="text-xs text-neutral-500 dark:text-neutral-400 w-10">High</label>
                      <input
                        type="color"
                        value={heatmapColors.token.end}
                        onChange={(event) =>
                          setHeatmapColors((prev) => ({
                            ...prev,
                            token: { ...prev.token, end: event.target.value },
                          }))
                        }
                        className="w-8 h-8 rounded border border-neutral-300 dark:border-neutral-600 cursor-pointer"
                      />
                      <span className="text-xs font-mono text-neutral-500">
                        {heatmapColors.token.end}
                      </span>
                    </div>
                  </div>
                </div>
                <div className="mt-4">
                  <span className="text-xs text-neutral-500 dark:text-neutral-400">Preview</span>
                  <div
                    className="mt-1 h-4 rounded"
                    style={{
                      background: `linear-gradient(to right, ${heatmapColors.line.start}, ${heatmapColors.line.end})`,
                    }}
                  />
                </div>
              </div>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Worktree Location
              </h2>
            </div>
            <div className="p-4">
              <label className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2">
                Custom Worktree Path
              </label>
              <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                Specify where to store git worktrees. Leave empty to use the default location.
              </p>
              <input
                type="text"
                value={worktreePath}
                onChange={(event) => setWorktreePath(event.target.value)}
                className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100"
                placeholder="~/my-custom-worktrees"
                autoComplete="off"
              />
              <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-2">
                Default location: ~/cmux
              </p>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                AI Provider Authentication
              </h2>
            </div>
            <div className="p-4">
              <div className="space-y-3">
                {MOCK_API_KEYS.length === 0 ? (
                  <p className="text-sm text-neutral-500 dark:text-neutral-400">
                    No API keys required for the configured agents.
                  </p>
                ) : (
                  <>
                    <div className="mb-3">
                      <h3 className="text-sm font-medium text-neutral-900 dark:text-neutral-100 mb-1">
                        API Key Authentication
                      </h3>
                      <div className="text-xs text-neutral-500 dark:text-neutral-400 space-y-1">
                        <p>You can authenticate providers in two ways:</p>
                        <ul className="list-disc ml-4 space-y-0.5">
                          <li>
                            Start a coding CLI (Claude Code, Codex CLI, Gemini CLI, Amp, Opencode) and complete its sign-in; cmux reuses that authentication.
                          </li>
                          <li>Or enter API keys here and cmux will use them directly.</li>
                        </ul>
                      </div>
                    </div>

                    {MOCK_API_KEYS.map((key) => {
                      const providerInfo = PROVIDER_INFO[key.envVar];
                      const usedModels = API_KEY_MODELS_BY_ENV[key.envVar] ?? [];
                      const isExpanded = expandedUsedList[key.envVar] ?? false;
                      const shouldTruncate = usedModels.length > 3 && !isExpanded;
                      const placeholder =
                        key.envVar === "CLAUDE_CODE_OAUTH_TOKEN"
                          ? "sk-ant-oat01-..."
                          : key.envVar === "ANTHROPIC_API_KEY"
                            ? "sk-ant-api03-..."
                            : key.envVar === "OPENAI_API_KEY"
                              ? "sk-proj-..."
                              : key.envVar === "OPENROUTER_API_KEY"
                                ? "sk-or-v1-..."
                                : `Enter your ${key.displayName}`;

                      return (
                        <div
                          key={key.envVar}
                          className="border border-neutral-200 dark:border-neutral-800 rounded-lg p-3 space-y-2"
                        >
                          <div className="flex-1 min-w-0">
                            <div className="flex items-start justify-between">
                              <div className="min-w-0">
                                <label
                                  htmlFor={key.envVar}
                                  className="block text-sm font-medium text-neutral-700 dark:text-neutral-300"
                                >
                                  {key.displayName}
                                </label>
                                {providerInfo?.helpText ? (
                                  <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">
                                    {providerInfo.helpText}
                                  </p>
                                ) : null}
                                {usedModels.length > 0 ? (
                                  <div className="mt-1 space-y-1">
                                    <div className="flex items-center gap-2 min-w-0">
                                      <p className="text-xs text-neutral-500 dark:text-neutral-400 flex-1 min-w-0">
                                        Used for agents:{" "}
                                        <span className="inline-flex items-center gap-1 min-w-0 align-middle w-full">
                                          <span
                                            className={clsx(
                                              "font-medium min-w-0",
                                              shouldTruncate
                                                ? "flex-1 truncate"
                                                : "flex-1 whitespace-normal break-words"
                                            )}
                                          >
                                            {usedModels.join(", ")}
                                          </span>
                                          {usedModels.length > 3 ? (
                                            <button
                                              type="button"
                                              onClick={() =>
                                                setExpandedUsedList((prev) => ({
                                                  ...prev,
                                                  [key.envVar]: !isExpanded,
                                                }))
                                              }
                                              className="flex-none text-[10px] text-blue-600 hover:underline dark:text-blue-400"
                                            >
                                              {isExpanded ? "Hide more" : "Show more"}
                                            </button>
                                          ) : null}
                                        </span>
                                      </p>
                                    </div>
                                  </div>
                                ) : null}
                              </div>
                              {providerInfo?.url ? (
                                <a
                                  href={providerInfo.url}
                                  target="_blank"
                                  rel="noopener noreferrer"
                                  className="text-xs text-blue-500 hover:text-blue-600 dark:text-blue-400 dark:hover:text-blue-300 flex items-center gap-1 whitespace-nowrap"
                                >
                                  Get key
                                  <svg
                                    className="w-3 h-3"
                                    fill="none"
                                    stroke="currentColor"
                                    viewBox="0 0 24 24"
                                  >
                                    <path
                                      strokeLinecap="round"
                                      strokeLinejoin="round"
                                      strokeWidth={2}
                                      d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
                                    />
                                  </svg>
                                </a>
                              ) : null}
                            </div>
                          </div>

                          <div className="md:w-[min(100%,480px)] md:flex-shrink-0 self-start">
                            {key.envVar === "CODEX_AUTH_JSON" ? (
                              <div className="relative">
                                {showKeys[key.envVar] ? (
                                  <textarea
                                    id={key.envVar}
                                    value={apiKeyValues[key.envVar] || ""}
                                    onChange={(event) =>
                                      handleApiKeyChange(key.envVar, event.target.value)
                                    }
                                    rows={4}
                                    className="w-full px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 font-mono text-xs resize-y"
                                    placeholder='{"tokens": {"id_token": "...", "access_token": "...", "refresh_token": "...", "account_id": "..."}, "last_refresh": "..."}'
                                  />
                                ) : (
                                  <div
                                    onClick={() => toggleShowKey(key.envVar)}
                                    className="w-full px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 font-mono text-xs cursor-pointer h-[82px]"
                                  >
                                    {apiKeyValues[key.envVar] ? (
                                      "••••••••••••••••••••••••••••••••"
                                    ) : (
                                      <span className="text-neutral-400">Click to edit</span>
                                    )}
                                  </div>
                                )}
                                <button
                                  type="button"
                                  onClick={() => toggleShowKey(key.envVar)}
                                  className="absolute top-2 right-2 p-1 text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
                                >
                                  {showKeys[key.envVar] ? (
                                    <EyeOff className="h-5 w-5" />
                                  ) : (
                                    <Eye className="h-5 w-5" />
                                  )}
                                </button>
                              </div>
                            ) : (
                              <div className="relative">
                                <input
                                  type={showKeys[key.envVar] ? "text" : "password"}
                                  id={key.envVar}
                                  value={apiKeyValues[key.envVar] || ""}
                                  onChange={(event) =>
                                    handleApiKeyChange(key.envVar, event.target.value)
                                  }
                                  className="w-full px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 font-mono text-xs"
                                  placeholder={placeholder}
                                />
                                <button
                                  type="button"
                                  onClick={() => toggleShowKey(key.envVar)}
                                  className="absolute inset-y-0 right-0 pr-3 flex items-center text-neutral-500"
                                >
                                  {showKeys[key.envVar] ? (
                                    <EyeOff className="h-5 w-5" />
                                  ) : (
                                    <Eye className="h-5 w-5" />
                                  )}
                                </button>
                              </div>
                            )}
                            {apiKeyValues[key.envVar] ? (
                              <div className="flex items-center gap-1 mt-1">
                                <Check className="w-3 h-3 text-green-500 dark:text-green-400" />
                                <span className="text-xs text-green-600 dark:text-green-400">
                                  API key configured
                                </span>
                              </div>
                            ) : null}
                          </div>
                        </div>
                      );
                    })}
                  </>
                )}
              </div>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Provider Status
              </h2>
            </div>
            <div className="p-4">
              <div className="space-y-3">
                <div className="flex justify-end -mt-1 -mb-2">
                  <button
                    type="button"
                    onClick={handleRefreshStatus}
                    className="text-xs text-blue-600 dark:text-blue-400 hover:underline flex items-center gap-1"
                    disabled={isRefreshingStatus}
                  >
                    {isRefreshingStatus ? (
                      <RefreshCw className="w-3 h-3 animate-spin" />
                    ) : (
                      <RefreshCw className="w-3 h-3" />
                    )}
                    Refresh
                  </button>
                </div>
                <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-xs">
                  <div className="flex items-center gap-2">
                    {dockerOk ? (
                      <CheckCircle2 className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
                    ) : (
                      <XCircle className="w-3.5 h-3.5 text-red-500 flex-shrink-0" />
                    )}
                    <span className="text-xs text-neutral-700 dark:text-neutral-300 select-text">
                      Docker required 24.0
                    </span>
                  </div>

                  <div className="flex items-center gap-2">
                    {dockerImage.isAvailable ? (
                      <CheckCircle2 className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
                    ) : dockerImage.isPulling ? (
                      <RefreshCw className="w-3.5 h-3.5 text-blue-500 flex-shrink-0 animate-spin" />
                    ) : (
                      <AlertCircle className="w-3.5 h-3.5 text-yellow-500 flex-shrink-0" />
                    )}
                    <span className="text-xs text-neutral-700 dark:text-neutral-300 select-text">
                      {dockerImage.name}
                    </span>
                  </div>

                  <div className="flex items-center gap-2">
                    {gitOk ? (
                      <CheckCircle2 className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
                    ) : (
                      <XCircle className="w-3.5 h-3.5 text-red-500 flex-shrink-0" />
                    )}
                    <span className="text-xs text-neutral-700 dark:text-neutral-300 select-text">
                      Git 2.45
                    </span>
                  </div>

                  {providerRows.map((provider) => (
                    <div key={provider.name} className="flex items-center gap-2">
                      {provider.isAvailable ? (
                        <CheckCircle2 className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
                      ) : (
                        <AlertCircle className="w-3.5 h-3.5 text-yellow-500 flex-shrink-0" />
                      )}
                      <div className="min-w-0 flex flex-col">
                        <div className="flex items-center gap-1">
                          <span className="text-xs text-neutral-700 dark:text-neutral-300 select-text">
                            {provider.name}
                          </span>
                        </div>
                        {!provider.isAvailable && provider.missing ? (
                          <div className="text-xs text-neutral-500 dark:text-neutral-400 truncate">
                            {provider.missing}
                          </div>
                        ) : null}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>

          <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
            <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Container Management
              </h2>
            </div>
            <div className="p-4">
              <div className="space-y-6">
                <div>
                  <h3 className="text-lg font-medium text-neutral-900 dark:text-neutral-100">
                    Container Lifecycle Settings
                  </h3>
                  <p className="text-sm text-neutral-500 dark:text-neutral-400">
                    Configure how Docker containers are managed after tasks complete.
                  </p>
                </div>

                <div className="space-y-4">
                  <div className="flex items-center justify-between">
                    <div className="space-y-0.5">
                      <label htmlFor="auto-cleanup" className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                        Automatic Cleanup
                      </label>
                      <p className="text-sm text-neutral-500 dark:text-neutral-400">
                        Automatically stop containers based on the rules below
                      </p>
                    </div>
                    <SettingsSwitch
                      ariaLabel="Automatic Cleanup"
                      checked={containerSettings.autoCleanupEnabled}
                      onChange={(next) =>
                        setContainerSettings((prev) => ({
                          ...prev,
                          autoCleanupEnabled: next,
                        }))
                      }
                    />
                  </div>

                  <div className="space-y-2">
                    <label htmlFor="max-containers" className="block text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      Maximum Running Containers
                    </label>
                    <input
                      id="max-containers"
                      type="number"
                      min="1"
                      max="20"
                      value={containerSettings.maxRunningContainers}
                      onChange={(event) =>
                        setContainerSettings((prev) => ({
                          ...prev,
                          maxRunningContainers: Number.parseInt(event.target.value, 10) || 0,
                        }))
                      }
                      disabled={!containerSettings.autoCleanupEnabled}
                      className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 disabled:opacity-50"
                    />
                    <p className="text-sm text-neutral-500 dark:text-neutral-400">
                      Keep only the N most recently accessed containers running
                    </p>
                  </div>

                  <div className="flex items-center justify-between">
                    <div className="space-y-0.5">
                      <label htmlFor="stop-immediately" className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                        Stop Immediately on Completion
                      </label>
                      <p className="text-sm text-neutral-500 dark:text-neutral-400">
                        Stop containers as soon as tasks complete (no review period)
                      </p>
                    </div>
                    <SettingsSwitch
                      ariaLabel="Stop Immediately on Completion"
                      checked={containerSettings.stopImmediatelyOnCompletion}
                      disabled={!containerSettings.autoCleanupEnabled}
                      onChange={(next) =>
                        setContainerSettings((prev) => ({
                          ...prev,
                          stopImmediatelyOnCompletion: next,
                        }))
                      }
                    />
                  </div>

                  <div className="space-y-2">
                    <label htmlFor="min-containers" className="block text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      Always Keep Recent Containers
                    </label>
                    <input
                      id="min-containers"
                      type="number"
                      min="0"
                      max="20"
                      value={containerSettings.minContainersToKeep}
                      onChange={(event) =>
                        setContainerSettings((prev) => ({
                          ...prev,
                          minContainersToKeep: Number.parseInt(event.target.value, 10) || 0,
                        }))
                      }
                      disabled={!containerSettings.autoCleanupEnabled}
                      className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 disabled:opacity-50"
                    />
                    <p className="text-sm text-neutral-500 dark:text-neutral-400">
                      Always keep the N most recent containers alive, regardless of review period (0 = disabled)
                    </p>
                  </div>

                  <div className="space-y-2">
                    <label htmlFor="review-period" className="block text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      Review Period (minutes)
                    </label>
                    <input
                      id="review-period"
                      type="number"
                      min="10"
                      max="2880"
                      value={containerSettings.reviewPeriodMinutes}
                      onChange={(event) =>
                        setContainerSettings((prev) => ({
                          ...prev,
                          reviewPeriodMinutes: Number.parseInt(event.target.value, 10) || 0,
                        }))
                      }
                      disabled={
                        !containerSettings.autoCleanupEnabled ||
                        containerSettings.stopImmediatelyOnCompletion
                      }
                      className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 disabled:opacity-50"
                    />
                    <p className="text-sm text-neutral-500 dark:text-neutral-400">
                      {containerSettings.stopImmediatelyOnCompletion
                        ? "Review period is disabled when stopping immediately"
                        : "Keep containers running for this many minutes after task completion to allow code review"}
                    </p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div className="sticky bottom-0 border-t border-neutral-200 dark:border-neutral-800 bg-white/80 dark:bg-neutral-900/80 backdrop-blur supports-[backdrop-filter]:bg-white/60 supports-[backdrop-filter]:dark:bg-neutral-900/60">
        <div className="max-w-3xl mx-auto px-6 py-3 flex items-center justify-end gap-3">
          <button
            onClick={handleSave}
            disabled={!hasChanges || isSaving}
            className={`px-4 py-2 text-sm font-medium rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:focus:ring-offset-neutral-900 transition-all ${
              !hasChanges || isSaving
                ? "bg-neutral-200 dark:bg-neutral-800 text-neutral-400 dark:text-neutral-500 cursor-not-allowed opacity-50"
                : "bg-blue-600 dark:bg-blue-500 text-white hover:bg-blue-700 dark:hover:bg-blue-600"
            }`}
          >
            {isSaving ? "Saving..." : "Save Changes"}
          </button>
        </div>
      </div>
    </div>
  );
}

export default function FakeCmuxUI({
  variant = "dashboard",
  draggable = true,
  showDragHint: _showDragHint = true,
  className,
}: FakeCmuxUIProps) {
  const [position, setPosition] = useState({ x: 0, y: 0 });
  const [isDragging, setIsDragging] = useState(false);
  const [activeView, setActiveView] = useState<FakeCmuxUIVariant>(variant);
  const containerRef = useRef<HTMLDivElement>(null);
  const dragRef = useRef<{
    startX: number;
    startY: number;
    initialX: number;
    initialY: number;
  } | null>(null);

  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      if (!isDragging || !dragRef.current) return;
      const deltaX = e.clientX - dragRef.current.startX;
      const deltaY = e.clientY - dragRef.current.startY;

      const newX = Math.max(
        BOUNDS.minX,
        Math.min(BOUNDS.maxX, dragRef.current.initialX + deltaX)
      );
      const newY = Math.max(
        BOUNDS.minY,
        Math.min(BOUNDS.maxY, dragRef.current.initialY + deltaY)
      );

      setPosition({ x: newX, y: newY });
    };

    const handleMouseUp = () => {
      setIsDragging(false);
      dragRef.current = null;
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };

    if (isDragging) {
      window.addEventListener("mousemove", handleMouseMove);
      window.addEventListener("mouseup", handleMouseUp);
    }

    return () => {
      window.removeEventListener("mousemove", handleMouseMove);
      window.removeEventListener("mouseup", handleMouseUp);
    };
  }, [isDragging]);

  const handleMouseDown = (e: ReactMouseEvent<HTMLDivElement>) => {
    if (!draggable) return;
    if (!(e.target instanceof HTMLElement)) return;
    if (!e.target.closest("[data-drag-handle]")) return;
    e.preventDefault();
    setIsDragging(true);
    dragRef.current = {
      startX: e.clientX,
      startY: e.clientY,
      initialX: position.x,
      initialY: position.y,
    };
    document.body.style.cursor = "grabbing";
    document.body.style.userSelect = "none";
  };

  useEffect(() => {
    setActiveView(variant);
  }, [variant]);

  const homeView =
    variant === "environments" || variant === "settings" ? "dashboard" : variant;
  const activeNav: NavKey =
    activeView === "environments"
      ? "environments"
      : activeView === "settings"
        ? "settings"
        : "home";

  const handleNavSelect = (key: NavKey) => {
    if (key === "home") {
      setActiveView(homeView);
      return;
    }
    setActiveView(key === "environments" ? "environments" : "settings");
  };

  const titleBarLabel =
    activeView === "environments"
      ? "Environments"
      : activeView === "settings"
        ? "Settings"
        : "cmux";

  const categories = activeView === "tasks" ? runningCategories : taskCategories;

  return (
    <div
      ref={containerRef}
      className={`relative w-full max-w-7xl mx-auto ${className ?? ""}`}
      style={{
        transform: `translate(${position.x}px, ${position.y}px)`,
        transition: isDragging ? "none" : "transform 0.1s ease-out",
      }}
      onMouseDown={handleMouseDown}
    >
      <div className="bg-neutral-50 dark:bg-neutral-950 rounded-xl shadow-2xl shadow-black/60 border border-neutral-200 dark:border-neutral-800 overflow-hidden">
        <div className="flex h-[690px]">
          {/* Sidebar */}
          <div className="w-[310px] bg-neutral-50 dark:bg-black flex flex-col shrink-0 border-r border-neutral-200 dark:border-neutral-800 pr-1">
            <div
              data-drag-handle
              className="h-[38px] flex items-center pr-0.5 shrink-0 pl-3 cursor-grab active:cursor-grabbing"
            >
              <div className="flex gap-2 mr-3">
                <div className="w-3 h-3 rounded-full bg-[#ff5f57]" />
                <div className="w-3 h-3 rounded-full bg-[#febc2e]" />
                <div className="w-3 h-3 rounded-full bg-[#28c840]" />
              </div>
              <CmuxLogo height={32} className="text-neutral-900 dark:text-neutral-100" wordmarkFill="currentColor" />
              <div className="grow" />
              <button
                className="w-[25px] h-[25px] border border-neutral-200 dark:border-neutral-800 hover:bg-neutral-100 dark:hover:bg-neutral-900 rounded-lg flex items-center justify-center transition-colors"
                type="button"
              >
                <Plus className="w-4 h-4 text-neutral-700 dark:text-neutral-300" />
              </button>
            </div>

            <nav className="grow flex flex-col overflow-hidden">
              <div className="flex-1 overflow-y-auto pb-8">
                <ul className="flex flex-col gap-px">
                  {navItems.map((item) => (
                    <li key={item.label}>
                      <SidebarNavItem
                        item={item}
                        active={activeNav === item.key}
                        onClick={() => handleNavSelect(item.key)}
                      />
                    </li>
                  ))}
                </ul>

                <div className="mt-4 flex flex-col">
                  <div className="pointer-default cursor-default flex items-center rounded-sm pl-2 ml-2 pr-3 py-0.5 text-[12px] font-medium text-neutral-600 select-none hover:bg-neutral-200/45 dark:text-neutral-300 dark:hover:bg-neutral-800/45">
                    Pull requests
                  </div>
                  <div className="ml-2 pt-px">
                    <ul className="flex flex-col gap-px">
                      {pullRequests.map((pr) => (
                        <li key={`${pr.title}-${pr.repo}`}>
                          <SidebarListItem
                            title={pr.title}
                            secondary={pr.repo}
                            toggleVisible
                            meta={<PullRequestIcon status={pr.status} />}
                            paddingLeft={10}
                          />
                        </li>
                      ))}
                    </ul>
                  </div>
                </div>

                <div className="mt-2 flex flex-col gap-0.5">
                  <div className="flex items-center justify-between ml-2">
                    <div className="pointer-default cursor-default flex items-center rounded-sm pl-2 pr-3 py-0.5 text-[12px] font-medium text-neutral-600 select-none hover:bg-neutral-200/45 dark:text-neutral-300 dark:hover:bg-neutral-800/45">
                      Workspaces
                    </div>
                    <button
                      className="p-1 mr-[3px] flex items-center justify-center text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 transition-colors"
                      type="button"
                    >
                      <Plus className="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>

                <div className="ml-2 pt-px">
                  <div className="space-y-px">
                    {sidebarTasks.map((task, index) => (
                      <div key={`${task.title}-${index}`}>
                        <SidebarListItem
                          title={task.title}
                          toggleVisible
                          expanded={Boolean(task.expanded)}
                          meta={<SidebarStatusIcon status={task.status} />}
                          paddingLeft={8}
                        />
                        {task.expanded && task.runs ? (
                          <div className="mt-px">
                            {task.runs.map((run, runIndex) => (
                              <div key={`${run.name}-${runIndex}`}>
                                <SidebarListItem
                                  title={run.name}
                                  toggleVisible={Boolean(run.children?.length)}
                                  expanded
                                  meta={<SidebarStatusIcon status={run.status} />}
                                  paddingLeft={26}
                                  titleClassName="text-[13px] text-neutral-700 dark:text-neutral-300"
                                />
                                {run.children ? (
                                  <div>
                                    {run.children.map((child, childIndex) => (
                                      <TaskRunDetailRow
                                        key={`${child.label}-${childIndex}`}
                                        icon={
                                          child.type === "vscode" ? (
                                            <VSCodeIcon className="w-3 h-3 mr-2 text-neutral-400 grayscale opacity-60" />
                                          ) : (
                                            <GitCompare className="w-3 h-3 mr-2 text-neutral-400" />
                                          )
                                        }
                                        label={child.label}
                                        indentLevel={2}
                                        onClick={() => setActiveView(child.type === "vscode" ? "vscode" : "diff")}
                                      />
                                    ))}
                                  </div>
                                ) : null}
                              </div>
                            ))}
                          </div>
                        ) : null}
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </nav>
          </div>

          {/* Main area */}
          <div className="flex-1 bg-neutral-50 dark:bg-black">
            <div className="py-1.5 px-[5.8px] h-full flex flex-col">
              <div className="rounded-md border border-neutral-200/70 dark:border-neutral-800/50 flex flex-col grow min-h-0 h-full overflow-hidden bg-white dark:bg-neutral-900">
                <div
                  data-drag-handle
                  className="min-h-[24px] border-b border-neutral-200/70 dark:border-neutral-800/50 flex items-center justify-center text-xs font-medium text-neutral-600 dark:text-neutral-300 cursor-grab active:cursor-grabbing"
                >
                  {titleBarLabel}
                </div>

                <div className="flex-1 overflow-hidden min-h-0">
                  <div className="flex flex-col h-full">
                    {activeView === "dashboard" ? (
                      <div className="flex-1 flex flex-col pt-32 pb-0">
                        <div className="w-full max-w-6xl min-w-0 mx-auto px-4">
                          <DashboardInputCard />
                        </div>
                        <div className="w-full">
                          <DashboardTasks categories={categories} />
                        </div>
                      </div>
                    ) : null}
                    {activeView === "tasks" ? (
                      <div className="flex-1 flex flex-col pt-6 pb-0">
                        <div className="w-full">
                          <DashboardTasks categories={categories} />
                        </div>
                      </div>
                    ) : null}
                    {activeView === "diff" ? <DiffView /> : null}
                    {activeView === "vscode" ? <VSCodeView /> : null}
                    {activeView === "pr" ? <PullRequestView /> : null}
                    {activeView === "environments" ? <EnvironmentsView /> : null}
                    {activeView === "settings" ? <SettingsView /> : null}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

    </div>
  );
}
