import { dockerLogger } from "../utils/fileLogger";
import { extractSandboxStartError } from "../utils/sandboxErrors";
import { getWwwClient } from "../utils/wwwClient";
import { getWwwOpenApiModule } from "../utils/wwwOpenApiModule";
import {
  VSCodeInstance,
  type VSCodeInstanceConfig,
  type VSCodeInstanceInfo,
} from "./VSCodeInstance";

const {
  getApiSandboxesByIdStatus,
  postApiSandboxesByIdPublishDevcontainer,
  postApiSandboxesByIdStop,
  postApiSandboxesStart,
} = await getWwwOpenApiModule();

export class CmuxVSCodeInstance extends VSCodeInstance {
  private sandboxId: string | null = null;
  private workerUrl: string | null = null;
  private vscodeBaseUrl: string | null = null;
  private provider: VSCodeInstanceInfo["provider"] = "morph";
  private repoUrl?: string;
  private branch?: string;
  private newBranch?: string;
  private environmentId?: string;
  private taskRunJwt?: string;

  constructor(config: VSCodeInstanceConfig) {
    super(config);
    const cfg = config as VSCodeInstanceConfig & {
      repoUrl?: string;
      branch?: string;
      newBranch?: string;
      environmentId?: string;
      taskRunJwt?: string;
    };
    this.repoUrl = cfg.repoUrl;
    this.branch = cfg.branch;
    this.newBranch = cfg.newBranch;
    this.environmentId = cfg.environmentId;
    this.taskRunJwt = cfg.taskRunJwt;
  }

  async start(): Promise<VSCodeInstanceInfo> {
    dockerLogger.info(
      `[CmuxVSCodeInstance ${this.instanceId}] Requesting sandbox start via www API`
    );
    const startRes = await postApiSandboxesStart({
      client: getWwwClient(),
      body: {
        teamSlugOrId: this.teamSlugOrId,
        ttlSeconds: 60 * 60,
        metadata: {
          instance: `cmux-${this.taskRunId}`,
          agentName: this.config.agentName || "",
        },
        taskRunId: this.taskRunId,
        taskRunJwt: this.taskRunJwt || "",
        isCloudWorkspace: this.config.agentName === "cloud-workspace",
        ...(this.environmentId ? { environmentId: this.environmentId } : {}),
        ...(this.repoUrl
          ? {
            repoUrl: this.repoUrl,
            branch: this.branch,
            newBranch: this.newBranch,
            depth: 1,
          }
          : {}),
      },
    });
    const data = startRes.data;
    if (!data) {
      // Extract error details from the response for a more descriptive message
      const errorMessage = extractSandboxStartError(startRes);
      throw new Error(errorMessage);
    }

    this.sandboxId = data.instanceId;
    this.vscodeBaseUrl = data.vscodeUrl;
    this.workerUrl = data.workerUrl;
    this.provider = data.provider || "morph";
    const vscodePersisted = data.vscodePersisted ?? false;

    const workspaceUrl = this.getWorkspaceUrl(this.vscodeBaseUrl);
    dockerLogger.info(`[CmuxVSCodeInstance] VS Code URL: ${workspaceUrl}`);
    dockerLogger.info(`[CmuxVSCodeInstance] Worker URL: ${this.workerUrl}`);
    dockerLogger.info(
      `[CmuxVSCodeInstance] VSCode persisted by www: ${vscodePersisted}`
    );

    // Connect to the worker if available
    if (this.workerUrl) {
      try {
        await this.connectToWorker(this.workerUrl);
        dockerLogger.info(
          `[CmuxVSCodeInstance ${this.instanceId}] Connected to worker`
        );
      } catch (error) {
        dockerLogger.error(
          `[CmuxVSCodeInstance ${this.instanceId}] Failed to connect to worker`,
          error
        );
      }
    }

    return {
      url: this.vscodeBaseUrl!,
      workspaceUrl,
      instanceId: this.instanceId,
      taskRunId: this.taskRunId,
      provider: this.provider,
      vscodePersisted,
    };
  }

  async stop(): Promise<void> {
    this.stopFileWatch();
    if (this.sandboxId) {
      try {
        await postApiSandboxesByIdStop({
          client: getWwwClient(),
          path: { id: this.sandboxId },
        });
      } catch (e) {
        dockerLogger.warn(`[CmuxVSCodeInstance] stop failed`, e);
      }
    }
    await this.baseStop();
  }

  async getStatus(): Promise<{ running: boolean; info?: VSCodeInstanceInfo }> {
    if (!this.sandboxId) return { running: false };
    try {
      const res = await getApiSandboxesByIdStatus({
        client: getWwwClient(),
        path: { id: this.sandboxId },
        responseStyle: "data",
      });
      const st = res as unknown as {
        running: boolean;
        vscodeUrl?: string;
        workerUrl?: string;
        provider?: VSCodeInstanceInfo["provider"];
      };
      if (st.running && st.vscodeUrl) {
        return {
          running: true,
          info: {
            url: st.vscodeUrl,
            workspaceUrl: this.getWorkspaceUrl(st.vscodeUrl),
            instanceId: this.instanceId,
            taskRunId: this.taskRunId,
            provider: st.provider || this.provider,
          },
        };
      }
      return { running: false };
    } catch {
      return { running: false };
    }
  }

  // Bridge for agentSpawner to publish devcontainer networking (Morph-backed)
  async setupDevcontainer(): Promise<void> {
    if (!this.sandboxId) return;
    try {
      await postApiSandboxesByIdPublishDevcontainer({
        client: getWwwClient(),
        path: { id: this.sandboxId },
        body: {
          teamSlugOrId: this.teamSlugOrId,
          taskRunId: this.taskRunId,
        },
      });
    } catch (e) {
      dockerLogger.warn(
        `[CmuxVSCodeInstance] setupDevcontainer failed for sandbox ${this.sandboxId}`,
        e
      );
    }
  }

  getName(): string {
    return this.sandboxId || this.instanceId;
  }

  getWorkerUrl(): string | null {
    return this.workerUrl;
  }
}
