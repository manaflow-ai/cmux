import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type MouseEvent, type ReactNode } from "react";
import { Tooltip } from "@base-ui-components/react/tooltip";
import { CmdkMenu, type CmdkGroup } from "./components/CmdkMenu";
import { StatusRow } from "./components/StatusRow";
import { ActivityIndicatorBlock, AgentMessageRow, Blocks, ToolBlock, TurnActions, type ToolBlockVariant } from "./components/Transcript";
import { BarsIcon, PinwheelSpinner, ProviderIcon } from "./components/icons";
import { HintTooltip } from "./components/Tooltips";
import { useOverlayScrollbars } from "./hooks/useOverlayScrollbars";
import type { OptionValue, SessionOption } from "./session";
import {
  agentMessageBlocks,
  queuedAgentMessages,
  activityScenarios,
  galleryActions,
  galleryCommands,
  galleryOptions,
  galleryProviders,
  longConversationBlocks,
  stressConversationBlocks,
  turnSummaryBlocks,
} from "./gallery-fixtures";
import { groupTurns } from "./turns";
import { agentChatText } from "./i18n";
import { RepositorySlugContext } from "./context";

const cwd = "/Users/dev/project/agent-chat";
const noLoadingProviders = new Set<string>();
const codexModelsLoading = new Set(["codex"]);
const fixtureSha = (digit: string) => digit.repeat(64);
const humanMandateRef = "user-request:orchestration-lab-gallery-prototype";

type AdmissionCapability = { id: string; label: string; met: boolean };
type AdmissionReservation = {
  state: "none" | "held" | "pending" | "expired" | "released";
  lease_id?: string;
  expires_at?: string;
};
type AdmissionDependency = {
  state: "none" | "pending" | "failed" | "unknown";
  ref?: string;
  detail?: string;
};
type AdmissionAction = {
  kind: "dispatch" | "wait" | "reconcile" | "repair" | "request_authorization" | "escalate" | "none";
  detail: string;
};
type AdmissionProposal = {
  kind: "dispatch" | "wait" | "request_authorization";
  detail: string;
};
type AdmissionAuthorization = {
  state: "pending" | "not_required";
  detail: string;
};
type Admission = {
  decision: "admit" | "hold" | "wait" | "reject";
  displayLabel: string;
  capacity_reason: "available" | "reserved" | "dependency_blocked" | "capacity_unavailable" | "unknown";
  reason: string;
  required_capabilities: AdmissionCapability[];
  reservation: AdmissionReservation;
  dependency: AdmissionDependency;
  next_safe_action: AdmissionAction;
  proposal: AdmissionProposal;
  authorization: AdmissionAuthorization;
};

type OrchestrationStrategy = {
  id: string;
  label: string;
  description: string;
  task: string;
  status: string;
  sender: string;
  recipient: string;
  transport: string;
  transportId: "loopback" | "ssh" | "lease";
  hostId: string;
  owner: string;
  repo: string;
  worktree: string;
  branch: string;
  head: string;
  baseSha: string;
  headShaExact: string;
  artifactSha: string;
  queue: string;
  lease: string;
  stage: string;
  state: string;
  acceptance: string;
  kind: string;
  receiptStatus: "accepted" | "running" | "blocked" | "reviewed" | "verified" | "complete";
  health: string;
  guidance: string;
  evidence: string;
  artifacts: string;
  gap: string;
  nextAction: string;
  admission: Admission;
};

const orchestrationStrategies: OrchestrationStrategy[] = [
  {
    id: "local-queue",
    label: "Local queue",
    description: "Fast feedback for short, interactive work.",
    task: "orch-local-01",
    status: "running",
    sender: "cmux-chat",
    recipient: "local-supervisor",
    transport: "loopback",
    transportId: "loopback",
    hostId: "local-supervisor-fixture",
    owner: "gallery-fixture",
    repo: "cmux",
    worktree: "agent-chat",
    branch: "feat-cmux-next",
    head: "4ce7c9c1…",
    baseSha: fixtureSha("1"),
    headShaExact: fixtureSha("2"),
    artifactSha: fixtureSha("3"),
    queue: "2 queued · 1/4 active",
    lease: "09:42 remaining",
    stage: "working",
    state: "running",
    acceptance: "accepted",
    kind: "progress",
    receiptStatus: "running",
    health: "healthy",
    guidance: "sha256:7d2a…",
    evidence: "receipt.json",
    artifacts: "gallery.js",
    gap: "none",
    nextAction: "Run next bounded task",
    admission: {
      decision: "admit",
      displayLabel: "Admit to local queue",
      capacity_reason: "available",
      reason: "A local slot is available and the task stays within the bounded fixture budget.",
      required_capabilities: [
        { id: "loopback", label: "loopback transport", met: true },
        { id: "active-slot", label: "4 active slots", met: true },
        { id: "fixture-guidance", label: "fixture guidance", met: true },
      ],
      reservation: { state: "held", lease_id: "lease-local-01", expires_at: "fixture+09:42" },
      dependency: { state: "none" },
      next_safe_action: { kind: "dispatch", detail: "Run the next bounded task and record its receipt." },
      proposal: { kind: "dispatch", detail: "Start orch-local-01 on the local supervisor" },
      authorization: { state: "not_required", detail: "Fixture scope permits preview only; dispatch remains disabled." },
    },
  },
  {
    id: "huge-blue",
    label: "Huge Blue lease",
    description: "Reserved Linux capacity for heavier verification.",
    task: "orch-huge-blue-07",
    status: "reserved",
    sender: "cmux-chat",
    recipient: "huge-blue-supervisor",
    transport: "ssh · enrolled host",
    transportId: "ssh",
    hostId: "huge-blue-fixture",
    owner: "gallery-fixture",
    repo: "cmux",
    worktree: "/home/leo/…/cmux",
    branch: "feat-cmux-next",
    head: "ce704bfb…",
    baseSha: fixtureSha("4"),
    headShaExact: fixtureSha("5"),
    artifactSha: fixtureSha("6"),
    queue: "5 queued · 0/8 active",
    lease: "17:30 remaining",
    stage: "acknowledged",
    state: "running",
    acceptance: "conditional",
    kind: "review",
    receiptStatus: "reviewed",
    health: "degraded",
    guidance: "sha256:14b8…",
    evidence: "rust-green-receipt.json",
    artifacts: "acpmux binary",
    gap: "dogfood gate held",
    nextAction: "Reconcile controller cleanup",
    admission: {
      decision: "hold",
      displayLabel: "Hold for cleanup review",
      capacity_reason: "dependency_blocked",
      reason: "The host is reserved, but the controller cleanup proof is still held.",
      required_capabilities: [
        { id: "enrolled-ssh", label: "enrolled SSH host", met: true },
        { id: "linux-x86_64", label: "linux-x86_64", met: true },
        { id: "rust-toolchain", label: "Rust toolchain", met: true },
      ],
      reservation: { state: "held", lease_id: "lease-huge-blue-07", expires_at: "fixture+17:30" },
      dependency: { state: "pending", ref: "controller-cleanup-receipt", detail: "Revised controller cleanup receipt" },
      next_safe_action: { kind: "reconcile", detail: "Reconcile cleanup evidence before requesting admission." },
      proposal: { kind: "request_authorization", detail: "Request orch-huge-blue-07 after cleanup proof" },
      authorization: { state: "pending", detail: "Proposal only; human authorization is required for admission." },
    },
  },
  {
    id: "cloud-fair-share",
    label: "Cloud fair-share",
    description: "Shared capacity with fairness and retry budgets.",
    task: "orch-cloud-12",
    status: "queued",
    sender: "cmux-chat",
    recipient: "cloud-router",
    transport: "durable lease",
    transportId: "lease",
    hostId: "cloud-router-fixture",
    owner: "gallery-fixture",
    repo: "cmux",
    worktree: "managed-worktree",
    branch: "main",
    head: "a81f6de2…",
    baseSha: fixtureSha("7"),
    headShaExact: fixtureSha("8"),
    artifactSha: fixtureSha("9"),
    queue: "12 queued · 0/32 active",
    lease: "starts on admission",
    stage: "submitted",
    state: "submitted",
    acceptance: "pending",
    kind: "next-work",
    receiptStatus: "blocked",
    health: "unknown",
    guidance: "sha256:91c4…",
    evidence: "admission receipt",
    artifacts: "pending",
    gap: "capacity unavailable",
    nextAction: "Proposal · human authorization required: Wait for fair-share slot",
    admission: {
      decision: "wait",
      displayLabel: "Wait for fair-share capacity",
      capacity_reason: "capacity_unavailable",
      reason: "No fair-share slot is available inside the current capacity budget.",
      required_capabilities: [
        { id: "durable-lease", label: "durable lease", met: true },
        { id: "fair-share", label: "fair-share queue", met: false },
        { id: "retry-budget", label: "retry budget", met: true },
      ],
      reservation: { state: "pending" },
      dependency: { state: "unknown", detail: "Capacity unavailable" },
      next_safe_action: { kind: "wait", detail: "Keep the proposal queued and re-evaluate when a slot opens." },
      proposal: { kind: "wait", detail: "Claim the next fair-share slot for orch-cloud-12" },
      authorization: { state: "pending", detail: "Proposal only; human authorization is required to wait or claim." },
    },
  },
];

function setOption(options: SessionOption[], id: string, value: OptionValue): SessionOption[] {
  return options.map((o) => o.id === id ? { ...o, value } : o);
}

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section className="gallery-section" id={id}>
      <h2>{title}</h2>
      <div className="gallery-section-body">{children}</div>
    </section>
  );
}

function AdmissionDecision({ strategy }: { strategy: OrchestrationStrategy }) {
  const { admission } = strategy;
  return (
    <section className="orchestration-admission" aria-label={`${strategy.label} admission decision`}>
      <div className="orchestration-admission-heading">
        <div>
          <div className="orchestration-inspector-kicker">Admission decision · fixture preview</div>
          <h4>{admission.displayLabel}</h4>
        </div>
        <span className={`orchestration-admission-badge orchestration-admission-${admission.decision}`}>
          {admission.decision}
        </span>
      </div>
      <p className="orchestration-admission-reason">{admission.reason}</p>
      <div className="orchestration-action-path" aria-label="Action path">
        <div className="orchestration-action-step">
          <span className="orchestration-action-index">1</span>
          <span><strong>Decision</strong><b>{admission.decision}</b></span>
        </div>
        <div className="orchestration-action-step">
          <span className="orchestration-action-index">2</span>
          <span><strong>Blocker</strong><b>{admission.dependency.state === "none" ? admission.capacity_reason : admission.dependency.detail ?? admission.dependency.state}</b></span>
        </div>
        <div className="orchestration-action-step action-step-next">
          <span className="orchestration-action-index">3</span>
          <span><strong>Next safe action</strong><b>{admission.next_safe_action.kind} · {admission.next_safe_action.detail}</b></span>
        </div>
      </div>
      <dl className="orchestration-admission-fields">
        <div>
          <dt>Required capabilities</dt>
          <dd><ul>{admission.required_capabilities.map((capability) => (
            <li className={capability.met ? "met" : "missing"} key={capability.id}>
              <span aria-hidden="true">{capability.met ? "✓" : "!"}</span> {capability.label}
            </li>
          ))}</ul></dd>
        </div>
        <div>
          <dt>Capacity reason</dt>
          <dd>{admission.capacity_reason}</dd>
        </div>
        <div>
          <dt>Reservation</dt>
          <dd>{admission.reservation.state}{admission.reservation.lease_id ? ` · ${admission.reservation.lease_id}` : ""}{admission.reservation.expires_at ? ` · ${admission.reservation.expires_at}` : ""}</dd>
        </div>
        <div>
          <dt>Blocking dependency</dt>
          <dd>{admission.dependency.state}{admission.dependency.ref ? ` · ${admission.dependency.ref}` : ""}{admission.dependency.detail ? ` · ${admission.dependency.detail}` : ""}</dd>
        </div>
        <div>
          <dt>Next safe action</dt>
          <dd><span className="orchestration-action-kind">{admission.next_safe_action.kind}</span> · {admission.next_safe_action.detail}</dd>
        </div>
      </dl>
      <div className="orchestration-proposal-grid">
        <div className="orchestration-proposal">
          <span className="orchestration-proposal-label">Proposal</span>
          <strong><span className="orchestration-action-kind">{admission.proposal.kind}</span> · {admission.proposal.detail}</strong>
        </div>
        <div className="orchestration-authorization">
          <span className="orchestration-proposal-label">Authorization · {admission.authorization.state}</span>
          <strong>{admission.authorization.detail}</strong>
        </div>
      </div>
    </section>
  );
}

function OrchestrationLab({ open }: { open: boolean }) {
  const [selectedId, setSelectedId] = useState(orchestrationStrategies[0].id);
  const routeButtonRefs = useRef<Record<string, HTMLButtonElement | null>>({});
  const selectedStrategy = orchestrationStrategies.find((strategy) => strategy.id === selectedId) ?? orchestrationStrategies[0];

  const selectRoute = (id: string) => setSelectedId(id);
  const handleRouteKeyDown = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    const direction = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1
      : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    const targetIndex = event.key === "Home" ? 0
      : event.key === "End" ? orchestrationStrategies.length - 1
      : direction ? (index + direction + orchestrationStrategies.length) % orchestrationStrategies.length : -1;
    if (targetIndex < 0) return;
    event.preventDefault();
    const target = orchestrationStrategies[targetIndex];
    selectRoute(target.id);
    routeButtonRefs.current[target.id]?.focus();
  };

  const blockerFor = (strategy: OrchestrationStrategy) => strategy.admission.dependency.state === "none"
    ? strategy.admission.capacity_reason
    : strategy.admission.dependency.detail ?? strategy.admission.dependency.state;

  if (!open) {
    return <div className="orchestration-collapsed" role="status">Orchestration lab hidden. Use the top-left toggle to reopen the fixture.</div>;
  }

  return (
    <div className="gallery-stack orchestration-lab">
      <div className="gallery-label">Fixture-only comparison surface. Values are redacted examples; no task is dispatched.</div>
      <section className="orchestration-route-compare" aria-label="Route comparison">
        <div className="orchestration-route-compare-heading">
          <div>
            <span className="orchestration-inspector-kicker">Route comparison</span>
            <p>Choose a route to inspect its typed receipt and action path.</p>
          </div>
          <span className="orchestration-route-compare-hint">Arrow keys select · Enter inspects</span>
        </div>
        <div className="orchestration-route-options" role="radiogroup" aria-label="Select a route for receipt inspection">
          {orchestrationStrategies.map((strategy, index) => {
            const selected = strategy.id === selectedId;
            return (
              <button
                key={strategy.id}
                id={`orchestration-route-${strategy.id}`}
                ref={(element) => { routeButtonRefs.current[strategy.id] = element; }}
                className={`orchestration-route-option${selected ? " selected" : ""}`}
                type="button"
                role="radio"
                aria-checked={selected}
                aria-controls="orchestration-receipt-inspector"
                tabIndex={selected ? 0 : -1}
                onClick={() => selectRoute(strategy.id)}
                onKeyDown={(event) => handleRouteKeyDown(event, index)}
              >
                <span className="orchestration-route-option-top">
                  <strong>{strategy.label}</strong>
                  <span className={`orchestration-admission-badge orchestration-admission-${strategy.admission.decision}`}>{strategy.admission.decision}</span>
                </span>
                <span className="orchestration-route-option-line"><b>Blocker</b>{blockerFor(strategy)}</span>
                <span className="orchestration-route-option-line"><b>Next</b>{strategy.admission.next_safe_action.detail}</span>
              </button>
            );
          })}
        </div>
      </section>
      <div className="orchestration-grid" role="list" aria-label="Orchestration strategies">
        {orchestrationStrategies.map((strategy) => {
          const selected = strategy.id === selectedId;
          return (
            <article className={`orchestration-card${selected ? " selected" : ""}`} key={strategy.id} role="listitem">
              <button
                className="orchestration-card-select"
                type="button"
                aria-pressed={selected}
                aria-controls="orchestration-receipt-inspector"
                onClick={() => selectRoute(strategy.id)}
              >
                <span className="orchestration-card-heading">
                  <span className="orchestration-card-title">{strategy.label}</span>
                  <span className={`orchestration-status orchestration-status-${strategy.status}`} aria-label={`Route phase ${strategy.status}`}>
                    <span className="sr-only">Route phase </span>{strategy.status}
                  </span>
                </span>
                <span className="orchestration-card-description">{strategy.description}</span>
              </button>
              <dl className="orchestration-fields">
                <div><dt>Task</dt><dd>{strategy.task}</dd></div>
                <div><dt>Sender → recipient</dt><dd>{strategy.sender} → {strategy.recipient}</dd></div>
                <div><dt>Transport</dt><dd>{strategy.transport}</dd></div>
                <div><dt>Repo / worktree / branch / head</dt><dd>{strategy.repo} / {strategy.worktree} / {strategy.branch} / {strategy.head}</dd></div>
                <div><dt>Queue</dt><dd>{strategy.queue}</dd></div>
                <div><dt>Lease TTL</dt><dd>{strategy.lease}</dd></div>
                <div><dt>Route health</dt><dd>{strategy.health}</dd></div>
                <div><dt>Guidance</dt><dd>{strategy.guidance}</dd></div>
                <div><dt>Evidence / artifacts</dt><dd>{strategy.evidence} / {strategy.artifacts}</dd></div>
                <div><dt>Gap</dt><dd>{strategy.gap}</dd></div>
                <div><dt>Next action</dt><dd>{strategy.nextAction}</dd></div>
              </dl>
            </article>
          );
        })}
      </div>
      <section id="orchestration-receipt-inspector" className="orchestration-inspector" aria-label={`${selectedStrategy.label} receipt preview`} aria-live="polite">
        <div className="orchestration-inspector-header">
          <div>
            <div className="orchestration-inspector-kicker">Focused receipt preview · non-contract display sample</div>
            <h3>{selectedStrategy.label}</h3>
          </div>
          <div className="orchestration-inspector-phase">
            <span className="orchestration-inspector-phase-label">Route phase</span>
            <span className={`orchestration-status orchestration-status-${selectedStrategy.status}`}>{selectedStrategy.status}</span>
          </div>
        </div>
        <dl className="orchestration-receipt-summary">
          <div><dt>Task</dt><dd>{selectedStrategy.task}</dd></div>
          <div><dt>Route</dt><dd>{selectedStrategy.transport} · {selectedStrategy.recipient}</dd></div>
          <div><dt>Stage</dt><dd>{selectedStrategy.stage}</dd></div>
          <div><dt>State</dt><dd>{selectedStrategy.state}</dd></div>
          <div><dt>Receipt status</dt><dd>{selectedStrategy.receiptStatus}</dd></div>
          <div><dt>Acceptance</dt><dd>{selectedStrategy.acceptance}</dd></div>
          <div><dt>Route health</dt><dd>{selectedStrategy.health}</dd></div>
          <div><dt>Lease</dt><dd>{selectedStrategy.lease}</dd></div>
          <div><dt>Guidance</dt><dd>{selectedStrategy.guidance}</dd></div>
          <div><dt>Evidence</dt><dd>{selectedStrategy.evidence}</dd></div>
          <div><dt>Next action</dt><dd>{selectedStrategy.nextAction}</dd></div>
        </dl>
        <AdmissionDecision strategy={selectedStrategy} />
        <pre className="orchestration-receipt-preview" aria-label="Non-contract display sample: receipt-shaped fixture with context">{JSON.stringify({
          receipt: {
            schema_version: 1,
            message_id: "redacted",
            task_id: selectedStrategy.task,
            in_reply_to: "redacted",
            sender: selectedStrategy.sender,
            recipient: selectedStrategy.recipient,
            transport: selectedStrategy.transportId,
            host_id: selectedStrategy.hostId,
            session_id: "redacted",
            root_id: "gallery-fixture",
            owner: selectedStrategy.owner,
            authority_ref: humanMandateRef,
            stage: selectedStrategy.stage,
            state: selectedStrategy.state,
            kind: selectedStrategy.kind,
            status: selectedStrategy.receiptStatus,
            acceptance: selectedStrategy.acceptance,
            repository: selectedStrategy.repo,
            worktree: selectedStrategy.worktree,
            branch: selectedStrategy.branch,
            base_sha: selectedStrategy.baseSha,
            head_sha: selectedStrategy.headShaExact,
            command: `gallery.fixture --strategy ${selectedStrategy.id}`,
            assertion_count: 0,
            artifact_sha: selectedStrategy.artifactSha,
            artifacts: { preview: "fixture-only" },
            evidence: [],
            gap: selectedStrategy.gap,
            next_action: selectedStrategy.nextAction,
          },
          fixture_context: {
            display_only: true,
            no_dispatch: true,
            redaction: "Hashes and command are deterministic fixture values; no command or task was executed.",
            authority: humanMandateRef,
            source_display: {
              head: selectedStrategy.head,
              repository: selectedStrategy.repo,
              worktree: selectedStrategy.worktree,
              branch: selectedStrategy.branch,
            },
            route: {
              id: selectedStrategy.id,
              label: selectedStrategy.transport,
              queue: selectedStrategy.queue,
              lease: selectedStrategy.lease,
              health: selectedStrategy.health,
            },
            guidance: {
              manifest: selectedStrategy.guidance,
              resolution: "fixture-only; no worker guidance loaded",
            },
            next_work: selectedStrategy.kind === "next-work"
              ? "Proposal only · human authorization required"
              : null,
          },
        }, null, 2)}</pre>
      </section>
    </div>
  );
}

function DemoStatusRow({
  provider,
  running = false,
  modelsLoading = false,
}: {
  provider: string;
  running?: boolean;
  modelsLoading?: boolean;
}) {
  const [options, setOptions] = useState(() => modelsLoading ? [] : galleryOptions[provider] ?? []);
  const [openOptionId, setOpenOptionId] = useState<string | null>(null);
  return (
    <div className="gallery-card compact">
      <StatusRow
        provider={provider}
        providers={galleryProviders}
        allProviderOptions={modelsLoading ? {} : galleryOptions}
        loadingProviderIds={modelsLoading ? new Set([provider]) : noLoadingProviders}
        onProviderModelChange={(nextProvider, model) => console.log("gallery model", nextProvider, model)}
        cwd={cwd}
        options={options}
        onChange={(id, value) => setOptions((current) => setOption(current, id, value))}
        openOptionId={openOptionId}
        setOpenOptionId={setOpenOptionId}
        running={running}
      />
    </div>
  );
}

function ComposerMock({ state }: { state: "idle" | "starting" | "draft" | "error" | "loading-models" }) {
  const provider = state === "error" ? "claude" : "codex";
  const modelsLoading = state === "loading-models";
  const options = modelsLoading ? [] : galleryOptions[provider];
  const [openOptionId, setOpenOptionId] = useState<string | null>(null);
  return (
    <div className="gallery-composer-wrap">
      <div id="composer-card">
        <div className="input-wrap">
          <textarea
            id="prompt-input"
            readOnly
            disabled={state === "starting"}
            value={state === "draft" ? "Draft prompt with @src/App.tsx and /review" : ""}
            placeholder="Describe a task or ask a question..."
          />
        </div>
        <StatusRow
          provider={provider}
          providers={galleryProviders}
          allProviderOptions={modelsLoading ? {} : galleryOptions}
          loadingProviderIds={modelsLoading ? codexModelsLoading : noLoadingProviders}
          onProviderModelChange={(p, model) => console.log("gallery composer pick", p, model)}
          cwd={cwd}
          options={options}
          onChange={(id, value) => console.log("gallery composer option", id, value)}
          openOptionId={openOptionId}
          setOpenOptionId={setOpenOptionId}
          trailing={(
            <button className="send" type="button" aria-label="Start" disabled={state === "starting"}>
              {state === "starting" ? <PinwheelSpinner size={14} /> : <span aria-hidden>↑</span>}
            </button>
          )}
        />
      </div>
      {state === "error" ? <div className="composer-error">working directory does not exist: /missing/gallery/path</div> : null}
    </div>
  );
}

function pickerGroups(trigger: "/" | "$" | "@"): CmdkGroup[] {
  const group = galleryCommands.find((g) => g.trigger === trigger);
  return [{
    id: trigger,
    label: trigger === "@" ? "Files" : trigger === "$" ? "Skills" : "Commands",
    items: (group?.commands ?? []).map((cmd, i) => ({
      id: `${trigger}${cmd.name}`,
      label: `${trigger}${cmd.name}`,
      description: cmd.description,
      selected: i === 1,
      onSelect: () => console.log("gallery command", trigger, cmd.name),
    })),
  }];
}

function overflowGroups(): CmdkGroup[] {
  return galleryOptions.codex
    .filter((o) => ["approvals", "sandbox"].includes(o.id))
    .map((option) => ({
      id: option.id,
      label: option.label,
      items: (option.choices ?? []).map((choice) => ({
        id: `${option.id}:${choice.value}`,
        label: choice.label,
        description: choice.description,
        selected: choice.value === option.value,
        onSelect: () => console.log("gallery overflow", option.id, choice.value),
      })),
    }));
}

function optionGroups(option: SessionOption): CmdkGroup[] {
  return [{
    id: option.id,
    label: option.label,
    items: (option.choices ?? []).map((choice) => ({
      id: `${option.id}:${choice.value}`,
      label: choice.label,
      description: choice.description ?? choice.disabledReason,
      disabled: choice.disabled,
      selected: choice.value === option.value,
      icon: option.role === "effort" ? <BarsIcon filled={Math.max(1, Math.round((((option.choices ?? []).findIndex((c) => c.value === choice.value) + 1) / Math.max(1, option.choices?.length ?? 1)) * 4))} /> : undefined,
      onSelect: () => console.log("gallery option", option.id, choice.value),
    })),
  }];
}

const toolVariants: ToolBlockVariant[] = ["card", "inline", "rail", "oneliner", "terminal"];
const toolFixtures = [
  { kind: "tool" as const, toolId: "running", name: "bash", detail: "bun test", status: "running" as const },
  { kind: "tool" as const, toolId: "ok", name: "rg", detail: "SessionOption", status: "ok" as const, out: "src/App.tsx:850: SessionOption\nsrc/session.ts:24: SessionOption\n".repeat(8) },
  { kind: "tool" as const, toolId: "fail", name: "bash", detail: "bun run check", status: "fail" as const, out: "error TS2322: Type mismatch in a deliberately long line that should wrap or scroll without breaking the transcript column.\n" },
];

function GalleryPicker({ query = "" }: { query?: string }) {
  const installed = galleryProviders.filter((p) => p.installed !== false);
  const missing = galleryProviders.filter((p) => p.installed === false);
  const items = installed.flatMap((provider) => (galleryOptions[provider.id]?.find((o) => o.id === "model")?.choices ?? []).map((choice) => ({ provider, choice })))
    .filter(({ provider, choice }) => !query || `${provider.label} ${choice.label} ${choice.description ?? ""}`.toLowerCase().includes(query.toLowerCase()));
  return (
    <div className="model-picker-menu gallery-picker-static">
      <div className="model-picker-shell">
        {!query ? (
          <div className="model-picker-rail" role="tablist" aria-label="Harnesses">
            <div className="model-picker-rail-top">
              {installed.map((provider, i) => <button key={provider.id} className={"rail-btn" + (i === 0 ? " active" : "")}><ProviderIcon provider={provider} /></button>)}
            </div>
            <div className="model-picker-rail-bottom">
              {missing.map((provider) => <button key={provider.id} className="rail-btn missing"><ProviderIcon provider={provider} /></button>)}
            </div>
          </div>
        ) : null}
        <div className="model-picker-main">
          <div className="model-picker-search"><span>⌕</span><input readOnly value={query} placeholder="Search models..." /></div>
          <div className="model-picker-list">
            {items.length ? items.map(({ provider, choice }, i) => (
              <button key={`${provider.id}:${choice.value}`} className={"model-row" + (i === 1 ? " active" : "") + (choice.disabled ? " disabled" : "")}>
                <ProviderIcon provider={provider} />
                <span className="model-row-main">
                  <span className="model-row-name">{choice.label}</span>
                  <span className="model-row-subtitle">{choice.disabled ? choice.disabledReason : choice.description ?? provider.label}</span>
                </span>
              </button>
            )) : <div className="model-picker-empty">No models found</div>}
          </div>
        </div>
      </div>
    </div>
  );
}

export function GalleryApp() {
  useOverlayScrollbars();
  const [viewport, setViewport] = useState("1120px");
  const [orchestrationOpen, setOrchestrationOpen] = useState(true);
  const [focusedOrchestration, setFocusedOrchestration] = useState(false);
  useEffect(() => {
    const updateFocus = () => {
      setFocusedOrchestration(typeof window !== "undefined" && window.location.hash === "#orchestration-lab");
    };
    updateFocus();
    const previousTitle = document.title;
    document.title = "Orchestration preview · Fixture only · No dispatch";
    window.addEventListener("hashchange", updateFocus);
    return () => {
      window.removeEventListener("hashchange", updateFocus);
      document.title = previousTitle;
    };
  }, []);
  const toc = useMemo(() => [
    ["orchestration-lab", "Orchestration lab"],
    ["status-row", "Status row"],
    ["composer", "Composer"],
    ["picker", "Unified picker"],
    ["menus", "Menus"],
    ["commands", "Command menus"],
    ["tooltips", "Tooltips"],
    ["turn-summary", "Turn summary"],
    ["transcript", "Transcript"],
    ["stress-transcript", "Stress transcript"],
    ["activity", "Activity states"],
    ["turn-actions", "Turn actions"],
    ["tool-variants", "Tool call variants"],
    ["scrollbars", "Scrollbar behavior"],
  ], []);
  const effort = galleryOptions.claude.find((o) => o.id === "effort")!;
  const context = galleryOptions.claude.find((o) => o.id === "context")!;
  const mode = galleryOptions.claude.find((o) => o.id === "permissionMode")!;
  const clearOrchestrationFocus = (event: MouseEvent<HTMLAnchorElement>) => {
    event.preventDefault();
    if (typeof window !== "undefined") {
      window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}`);
    }
    setFocusedOrchestration(false);
  };
  return (
    <Tooltip.Provider delay={500} closeDelay={80} timeout={800}>
      <main id="gallery-main" className={focusedOrchestration ? "gallery-focused" : undefined}>
        <button
          className="orchestration-toggle"
          type="button"
          aria-controls="orchestration-lab"
          aria-expanded={orchestrationOpen}
          onClick={() => setOrchestrationOpen((open) => !open)}
        >
          <span className={`orchestration-toggle-dot${orchestrationOpen ? " active" : ""}`} aria-hidden="true" />
          <span>Orchestration preview</span>
          <span className="orchestration-toggle-note">Fixture only</span>
          <span className="orchestration-toggle-state">{orchestrationOpen ? "On" : "Off"}</span>
        </button>
        <header className={`gallery-header${focusedOrchestration ? " gallery-header-focused" : ""}`}>
          <h1>{focusedOrchestration ? "Orchestration lab · fixture preview" : "Agent Chat Gallery"}</h1>
          <p>{focusedOrchestration
            ? "A focused routing, admission, and receipt preview. No task is dispatched."
            : "Mock-driven visual QA surface. No WebSocket, no provider process, no live sessions."}</p>
          {focusedOrchestration && (
            <div className="orchestration-focus-signal orchestration-preview-guard" role="note" aria-label="Orchestration preview guard">
              <span><strong>Signal</strong> decision → blocker → next safe action</span>
              <span><strong>Preview</strong> fixture only · no dispatch</span>
              <span><strong>Trust override</strong> preview only</span>
              <span><strong>Authorization</strong> disabled</span>
              <span><strong>Proposal</strong> advisory</span>
            </div>
          )}
          {!focusedOrchestration && (
            <div className="gallery-viewports">
              {["320px", "480px", "660px", "900px", "1120px", "1400px"].map((w) => (
                <button key={w} className={viewport === w ? "active" : ""} onClick={() => setViewport(w)}>{w}</button>
              ))}
            </div>
          )}
          <nav className="gallery-toc" aria-label="Gallery sections">
            {toc.filter(([id]) => !focusedOrchestration || id === "orchestration-lab").map(([id, label]) => <a key={id} href={`#${id}`}>{label}</a>)}
          </nav>
          {focusedOrchestration && (
            <a className="gallery-focus-back" href="#gallery-main" onClick={clearOrchestrationFocus}>← Back to full gallery</a>
          )}
        </header>

        <div className="gallery-viewport-frame" style={{ maxWidth: viewport }}>
        <Section id="orchestration-lab" title="Orchestration lab">
          <OrchestrationLab open={orchestrationOpen} />
        </Section>
        {!focusedOrchestration && (<>
        <Section id="status-row" title="Status row">
          <div className="gallery-stack">
            {galleryProviders.map((provider) => (
              <div key={provider.id}>
                <div className="gallery-label">{provider.label} idle</div>
                <DemoStatusRow provider={provider.id} />
              </div>
            ))}
            {galleryProviders.filter((p) => p.installed !== false).map((provider) => (
              <div key={`${provider.id}:running`}>
                <div className="gallery-label">{provider.label} running</div>
                <DemoStatusRow provider={provider.id} running />
              </div>
            ))}
            <div>
              <div className="gallery-label">Codex models loading, running</div>
              <DemoStatusRow provider="codex" running modelsLoading />
            </div>
          </div>
        </Section>

        <Section id="composer" title="Composer">
          <div className="gallery-stack">
            <div><div className="gallery-label">Idle</div><ComposerMock state="idle" /></div>
            <div><div className="gallery-label">Draft</div><ComposerMock state="draft" /></div>
            <div><div className="gallery-label">Models loading</div><ComposerMock state="loading-models" /></div>
            <div><div className="gallery-label">Invalid cwd error</div><ComposerMock state="error" /></div>
          </div>
        </Section>

        <Section id="picker" title="Unified picker">
          <div className="gallery-grid two">
            <div><div className="gallery-label">Rail view, disabled row, not-installed rail item</div><GalleryPicker /></div>
            <div><div className="gallery-label">Searching view across harnesses</div><GalleryPicker query="gpt" /></div>
          </div>
        </Section>

        <Section id="menus" title="Effort, context, mode, overflow menus">
          <div className="gallery-grid">
            <div><div className="gallery-label">Effort menu</div><CmdkMenu groups={optionGroups(effort)} inline className="option-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Context menu</div><CmdkMenu groups={optionGroups(context)} inline className="option-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Mode menu</div><CmdkMenu groups={optionGroups(mode)} inline className="option-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Codex overflow</div><div className="overflow-menu menu gallery-inline-overflow"><CmdkMenu groups={overflowGroups()} inline /></div></div>
          </div>
        </Section>

        <Section id="commands" title="Command menus">
          <div className="gallery-grid">
            <div><div className="gallery-label">Slash commands</div><CmdkMenu groups={pickerGroups("/")} inline className="mention-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Codex skills</div><CmdkMenu groups={pickerGroups("$")} inline className="mention-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">File references</div><CmdkMenu groups={pickerGroups("@")} inline className="mention-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Empty state</div><CmdkMenu groups={[{ id: "empty", label: "No commands", items: [] }]} inline className="mention-menu gallery-inline-menu" /></div>
          </div>
        </Section>

        <Section id="tooltips" title="Tooltips">
          <div className="gallery-tooltip-row">
            {galleryProviders.slice(0, 4).map((provider) => (
              <HintTooltip key={provider.id} label={`Tooltip for ${provider.label}`}>
                <button className="row-control" type="button"><ProviderIcon provider={provider} /><span>{provider.label}</span></button>
              </HintTooltip>
            ))}
            <Tooltip.Root open>
              <Tooltip.Trigger render={<button className="row-control" type="button">Forced open</button>} />
              <Tooltip.Portal>
                <Tooltip.Positioner sideOffset={7}>
                  <Tooltip.Popup className="tooltip"><span>Forced tooltip preview</span><kbd>⌃⇧T</kbd></Tooltip.Popup>
                </Tooltip.Positioner>
              </Tooltip.Portal>
            </Tooltip.Root>
          </div>
        </Section>

        <Section id="turn-summary" title="Turn summary">
          <div className="gallery-grid two">
            <div className="gallery-transcript small">
              <div className="gallery-label">Collapsed summary</div>
              <Blocks blocks={turnSummaryBlocks} status="idle" actions={galleryActions} onFork={() => {}} forkPending={false} />
            </div>
            <div className="gallery-transcript small">
              <div className="gallery-label">Expanded activity list</div>
              <Blocks
                blocks={turnSummaryBlocks}
                status="idle"
                actions={galleryActions}
                onFork={() => {}}
                forkPending={false}
                initialExpandedTurns={{ [groupTurns(turnSummaryBlocks, "idle")[0].id]: true }}
              />
            </div>
            <div className="gallery-transcript small">
              <div className="gallery-label">One item expanded to detail</div>
              <Blocks
                blocks={turnSummaryBlocks}
                status="idle"
                actions={galleryActions}
                onFork={() => {}}
                forkPending={false}
                initialExpandedTurns={{ [groupTurns(turnSummaryBlocks, "idle")[0].id]: true }}
                initialExpandedItems={{ [`${groupTurns(turnSummaryBlocks, "idle")[0].id}:1`]: true }}
              />
            </div>
          </div>
        </Section>

        <Section id="agent-messages" title="cmux agent messages">
          <div className="gallery-grid two">
            <div className="gallery-transcript small">
              <div className="gallery-label">Delivered, in the turn they arrived in</div>
              <Blocks blocks={agentMessageBlocks} status="idle" actions={galleryActions} onFork={() => {}} forkPending={false} />
            </div>
            <div className="gallery-transcript small">
              <div className="gallery-label">Queued, above the composer</div>
              <div className="agent-messages-queued" role="status">
                <div className="agent-messages-queued-label">{agentChatText("agentMessageQueued")}</div>
                {queuedAgentMessages.map((message) => <AgentMessageRow key={message.id} message={message} />)}
              </div>
            </div>
          </div>
        </Section>

        <Section id="transcript" title={`Transcript (${longConversationBlocks.length} blocks)`}>
          <div className="gallery-transcript">
            <Blocks
              blocks={longConversationBlocks}
              status="idle"
              actions={galleryActions}
              onFork={() => console.log("gallery fork")}
              forkPending={false}
              thinkingDefaultOpen
              fileDiffs={{ "src/ChatMarkdown.tsx": "diff --git a/src/ChatMarkdown.tsx b/src/ChatMarkdown.tsx\nnew file mode 100644\n--- /dev/null\n+++ b/src/ChatMarkdown.tsx\n@@ -0,0 +1,3 @@\n+import ReactMarkdown from \"react-markdown\";\n+export function ChatMarkdown() {}\n+// highlighted diff preview" }}
            />
          </div>
        </Section>

        <Section id="stress-transcript" title={`Virtualization stress transcript (${stressConversationBlocks.length} blocks)`}>
          <div className="gallery-transcript">
            <Blocks blocks={stressConversationBlocks} status="idle" actions={galleryActions} onFork={() => {}} forkPending={false} />
          </div>
        </Section>

        <Section id="activity" title="Activity states">
          <div className="gallery-grid two">
            {activityScenarios.map((scenario) => (
              <div key={scenario.id} className="gallery-transcript small">
                <div className="gallery-label">{scenario.label}</div>
                <RepositorySlugContext.Provider value={scenario.repositorySlug ?? null}>
                  <Blocks blocks={scenario.blocks} status={scenario.status} actions={galleryActions} onFork={() => {}} forkPending={false} thinkingDefaultOpen />
                </RepositorySlugContext.Provider>
              </div>
            ))}
            <div className="gallery-transcript small">
              <div className="gallery-label">Elapsed indicator forced to 12s</div>
              <ActivityIndicatorBlock label="Thinking" startedAt={Date.now() - 12_000} />
            </div>
          </div>
        </Section>

        <Section id="turn-actions" title="Turn actions">
          <div className="gallery-card">
            <TurnActions stats="24289 in · 14 out · $0.18 · 5.9s" text="Markdown response body" actions={galleryActions} onFork={() => console.log("gallery fork")} forkPending={false} />
            <TurnActions stats="" text="No stats response" actions={galleryActions} onFork={() => console.log("gallery fork")} forkPending={false} copiedPreview />
            <TurnActions stats="100 in · 20 out · 2.1s" text="Pending fork response" actions={galleryActions} onFork={() => console.log("gallery fork")} forkPending />
          </div>
        </Section>

        <Section id="tool-variants" title="Tool call variants">
          <div className="gallery-tool-variants">
            {["480px", "100%"].map((width) => (
              <div className="gallery-tool-width" key={width} style={{ maxWidth: width }}>
                <div className="gallery-label">{width === "480px" ? "Narrow 480" : "Default width"}</div>
                {toolVariants.map((variant) => (
                  <div className="gallery-tool-variant" key={`${width}:${variant}`}>
                    <div className="gallery-label">{variant}</div>
                    {toolFixtures.map((tool) => (
                      <ToolBlock key={tool.toolId} b={tool} variant={variant} defaultOpen={tool.status !== "running"} />
                    ))}
                  </div>
                ))}
              </div>
            ))}
          </div>
        </Section>

        <Section id="scrollbars" title="Scrollbar behavior">
          <div className="gallery-scrollbox">
            {Array.from({ length: 60 }, (_, i) => <p key={i}>Scrollable gallery row {i}: overlay scrollbar thumb should appear only while scrolling.</p>)}
            <pre>{"wide ".repeat(80)}</pre>
          </div>
        </Section>
        </>)}
        </div>
      </main>
    </Tooltip.Provider>
  );
}
