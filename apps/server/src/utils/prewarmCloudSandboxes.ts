import type { Id } from "@cmux/convex/dataModel";
import type { PrewarmedSandboxInfo } from "../vscode/VSCodeInstance";
import { serverLogger } from "./fileLogger";
import {
  getAuthHeaderJson,
  getAuthToken,
  runWithAuth,
} from "./requestContext";
import { extractSandboxStartError } from "./sandboxErrors";
import { getWwwClient } from "./wwwClient";
import { getWwwOpenApiModule } from "./wwwOpenApiModule";

const PREWARM_TTL_SECONDS = 20 * 60;
const PREWARM_IDLE_TIMEOUT_MS = 10 * 60 * 1000;
const PREWARM_CLAIM_TIMEOUT_MS = 30 * 1000;

type TimeoutHandle = ReturnType<typeof setTimeout>;

type PrewarmEntryStatus = "starting" | "ready" | "failed";

export type PrewarmTarget = {
  teamSlugOrId: string;
  repoUrl?: string;
  branch?: string;
  environmentId?: Id<"environments">;
};

export type PrewarmStatus = {
  status: PrewarmEntryStatus;
  instanceId?: string;
  error?: string;
};

type PrewarmEntry = {
  targetKey: string;
  target: PrewarmTarget;
  status: PrewarmEntryStatus;
  instance?: PrewarmedSandboxInfo;
  error?: string;
  startedAt: number;
  readyPromise: Promise<PrewarmedSandboxInfo>;
  stopOnReady: boolean;
  claimed: boolean;
  expiryTimer?: TimeoutHandle;
  authToken?: string;
  authHeaderJson?: string;
};

class PrewarmCloudSandboxManager {
  private entries = new Map<string, PrewarmEntry>();

  async requestPrewarm(
    socketId: string,
    target: PrewarmTarget
  ): Promise<PrewarmStatus> {
    const validationError = this.validateTarget(target);
    if (validationError) {
      return { status: "failed", error: validationError };
    }

    const targetKey = this.buildTargetKey(target);
    const existing = this.entries.get(socketId);

    if (existing && existing.targetKey === targetKey) {
      return {
        status: existing.status,
        instanceId: existing.instance?.instanceId,
        error: existing.error,
      };
    }

    if (existing) {
      await this.cancelPrewarm(socketId, "target-changed");
    }

    const authToken = getAuthToken();
    const authHeaderJson = getAuthHeaderJson();
    const readyPromise = this.startSandbox(socketId, target);
    const entry: PrewarmEntry = {
      targetKey,
      target,
      status: "starting",
      startedAt: Date.now(),
      readyPromise,
      stopOnReady: false,
      claimed: false,
      authToken,
      authHeaderJson,
    };

    this.entries.set(socketId, entry);

    entry.readyPromise
      .then((instance) => {
        entry.status = "ready";
        entry.instance = instance;
        entry.error = undefined;

        if (entry.stopOnReady) {
          void this.stopSandbox(
            instance.instanceId,
            "prewarm-canceled",
            entry
          );
          this.clearEntry(socketId, entry);
          return;
        }

        if (!entry.claimed) {
          this.scheduleExpiry(socketId, entry);
        }
      })
      .catch((error) => {
        const message = error instanceof Error ? error.message : String(error);
        entry.status = "failed";
        entry.error = message;
        console.error("[Prewarm] Sandbox start failed", error);
        serverLogger.error("[Prewarm] Sandbox start failed", error);
        this.clearEntry(socketId, entry);
      });

    return { status: "starting" };
  }

  async claimPrewarm(
    socketId: string,
    target: PrewarmTarget
  ): Promise<PrewarmedSandboxInfo | null> {
    const validationError = this.validateTarget(target);
    if (validationError) {
      return null;
    }

    const targetKey = this.buildTargetKey(target);
    const entry = this.entries.get(socketId);
    if (!entry || entry.targetKey !== targetKey) {
      return null;
    }

    if (entry.status === "ready" && entry.instance) {
      entry.claimed = true;
      this.clearEntry(socketId, entry);
      return entry.instance;
    }

    if (entry.status !== "starting") {
      this.clearEntry(socketId, entry);
      return null;
    }

    entry.claimed = true;

    const resolved = await this.withTimeout(
      entry.readyPromise,
      PREWARM_CLAIM_TIMEOUT_MS
    );

    if (resolved) {
      this.clearEntry(socketId, entry);
      return resolved;
    }

    entry.claimed = false;
    await this.cancelPrewarm(socketId, "claim-timeout");
    return null;
  }

  async cancelPrewarm(socketId: string, reason: string): Promise<void> {
    const entry = this.entries.get(socketId);
    if (!entry) {
      return;
    }

    entry.stopOnReady = true;
    this.clearEntry(socketId, entry);
    serverLogger.info(`[Prewarm] Canceled prewarm (${reason}) for ${socketId}`);

    if (entry.status === "ready" && entry.instance) {
      await this.stopSandbox(entry.instance.instanceId, reason, entry);
    }
  }

  private buildTargetKey(target: PrewarmTarget): string {
    if (target.environmentId) {
      return `${target.teamSlugOrId}|env:${target.environmentId}`;
    }
    const repoUrl = target.repoUrl ?? "";
    const branch = target.branch ?? "";
    return `${target.teamSlugOrId}|repo:${repoUrl}|branch:${branch}`;
  }

  private validateTarget(target: PrewarmTarget): string | null {
    if (!target.teamSlugOrId) {
      return "Missing team slug";
    }
    if (target.environmentId) {
      return null;
    }
    if (!target.repoUrl) {
      return "Missing repo URL";
    }
    if (!target.branch) {
      return "Missing branch";
    }
    return null;
  }

  private async startSandbox(
    socketId: string,
    target: PrewarmTarget
  ): Promise<PrewarmedSandboxInfo> {
    const { postApiSandboxesStart } = await getWwwOpenApiModule();

    const body = {
      teamSlugOrId: target.teamSlugOrId,
      ttlSeconds: PREWARM_TTL_SECONDS,
      metadata: this.buildMetadata(target),
      ...(target.environmentId ? { environmentId: target.environmentId } : {}),
      ...(target.repoUrl
        ? { repoUrl: target.repoUrl, branch: target.branch, depth: 1 }
        : {}),
    };

    serverLogger.info("[Prewarm] Starting sandbox", {
      socketId,
      target,
    });

    const startRes = await postApiSandboxesStart({
      client: getWwwClient(),
      body,
    });

    const data = startRes.data;
    if (!data) {
      throw new Error(extractSandboxStartError(startRes));
    }

    return {
      instanceId: data.instanceId,
      vscodeUrl: data.vscodeUrl,
      workerUrl: data.workerUrl,
      provider: data.provider ?? "morph",
    };
  }

  private buildMetadata(target: PrewarmTarget): Record<string, string> {
    const metadata: Record<string, string> = {
      instance: `cmux-prewarm-${Date.now()}`,
      prewarm: "1",
    };

    if (target.environmentId) {
      metadata.environmentId = String(target.environmentId);
    }

    if (target.repoUrl) {
      metadata.repoUrl = target.repoUrl;
    }

    if (target.branch) {
      metadata.branch = target.branch;
    }

    return metadata;
  }

  private scheduleExpiry(socketId: string, entry: PrewarmEntry): void {
    this.clearExpiry(entry);

    entry.expiryTimer = setTimeout(() => {
      if (entry.status !== "ready" || entry.claimed || entry.stopOnReady) {
        return;
      }

      serverLogger.info("[Prewarm] Expiring unused sandbox", {
        socketId,
        instanceId: entry.instance?.instanceId,
      });

      entry.stopOnReady = true;
      if (entry.instance) {
        void this.stopSandbox(entry.instance.instanceId, "idle-timeout", entry);
      }

      this.clearEntry(socketId, entry);
    }, PREWARM_IDLE_TIMEOUT_MS);
  }

  private clearEntry(socketId: string, entry: PrewarmEntry): void {
    this.clearExpiry(entry);
    const current = this.entries.get(socketId);
    if (current === entry) {
      this.entries.delete(socketId);
    }
  }

  private clearExpiry(entry: PrewarmEntry): void {
    if (entry.expiryTimer) {
      clearTimeout(entry.expiryTimer);
      entry.expiryTimer = undefined;
    }
  }

  private async stopSandbox(
    instanceId: string,
    reason: string,
    entry: PrewarmEntry
  ): Promise<void> {
    const stop = async () => {
      const { postApiSandboxesByIdStop } = await getWwwOpenApiModule();
      await postApiSandboxesByIdStop({
        client: getWwwClient(),
        path: { id: instanceId },
      });
      serverLogger.info("[Prewarm] Stopped sandbox", {
        instanceId,
        reason,
      });
    };

    try {
      if (entry.authHeaderJson) {
        await runWithAuth(entry.authToken, entry.authHeaderJson, stop);
        return;
      }
      await stop();
    } catch (error) {
      console.error("[Prewarm] Failed to stop sandbox", error);
      serverLogger.error("[Prewarm] Failed to stop sandbox", error);
    }
  }

  private async withTimeout<T>(
    promise: Promise<T>,
    timeoutMs: number
  ): Promise<T | null> {
    let timeoutHandle: TimeoutHandle | undefined;
    const timeoutPromise: Promise<T | null> = new Promise((resolve) => {
      timeoutHandle = setTimeout(() => resolve(null), timeoutMs);
    });

    try {
      const result = await Promise.race([promise, timeoutPromise]);
      if (timeoutHandle) {
        clearTimeout(timeoutHandle);
      }
      if (result === null) {
        return null;
      }
      return result;
    } catch (error) {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle);
      }
      console.error("[Prewarm] Failed to await sandbox readiness", error);
      serverLogger.error("[Prewarm] Failed to await sandbox readiness", error);
      return null;
    }
  }
}

export const prewarmCloudSandboxManager = new PrewarmCloudSandboxManager();
