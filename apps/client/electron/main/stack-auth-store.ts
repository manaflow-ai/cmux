import { app, type Session } from "electron";
import {
  mkdir,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { dirname, join } from "node:path";

const STORE_FILENAME = "stack-auth.json";
const FILE_VERSION = 1;

type StoredToken = {
  value: string;
  expiresAt: number;
};

type StoredStackAuth = {
  version: number;
  projectId: string;
  cookieUrl: string;
  refresh: StoredToken;
  access?: StoredToken | null;
  updatedAt: string;
};

type PersistArgs = {
  projectId: string;
  cookieUrl: string;
  refresh: StoredToken;
  access: StoredToken;
  log?: (...args: unknown[]) => void;
  warn?: (...args: unknown[]) => void;
};

type RestoreArgs = {
  session: Session;
  projectId: string;
  fallbackCookieUrl: string;
  log?: (...args: unknown[]) => void;
  warn?: (...args: unknown[]) => void;
};

type ClearArgs = {
  warn?: (...args: unknown[]) => void;
};

type RestoreResult = {
  restored: boolean;
  reason?: string;
};

function storagePath(): string {
  const userDataDir = app.getPath("userData");
  return join(userDataDir, STORE_FILENAME);
}

async function writeJsonAtomic(filePath: string, data: StoredStackAuth): Promise<void> {
  const dir = dirname(filePath);
  await mkdir(dir, { recursive: true });
  const tempPath = `${filePath}.tmp`;
  const payload = JSON.stringify(data);
  await writeFile(tempPath, payload, { encoding: "utf8" });
  try {
    await rm(filePath, { force: true });
  } catch {
    // ignore inability to remove existing file
  }
  await rename(tempPath, filePath);
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function normalizeCookieUrl(maybeUrl: string, fallback: string): string {
  try {
    const parsed = new URL(maybeUrl);
    parsed.hash = "";
    return parsed.toString();
  } catch {
    return fallback;
  }
}

export async function persistStackTokens({
  projectId,
  cookieUrl,
  refresh,
  access,
  log,
  warn,
}: PersistArgs): Promise<void> {
  if (!refresh.value || !isFiniteNumber(refresh.expiresAt)) {
    warn?.("[StackAuthStore] Refusing to persist invalid refresh token metadata");
    return;
  }
  if (!access.value || !isFiniteNumber(access.expiresAt)) {
    warn?.("[StackAuthStore] Refusing to persist invalid access token metadata");
    return;
  }

  const normalizedUrl = normalizeCookieUrl(cookieUrl, cookieUrl);
  const filePath = storagePath();
  const payload: StoredStackAuth = {
    version: FILE_VERSION,
    projectId,
    cookieUrl: normalizedUrl,
    refresh: {
      value: refresh.value,
      expiresAt: Math.floor(refresh.expiresAt),
    },
    access: {
      value: access.value,
      expiresAt: Math.floor(access.expiresAt),
    },
    updatedAt: new Date().toISOString(),
  };

  try {
    await writeJsonAtomic(filePath, payload);
    log?.("[StackAuthStore] Persisted Stack tokens", {
      filePath,
      refreshExpiresAt: payload.refresh.expiresAt,
      accessExpiresAt: payload.access?.expiresAt ?? null,
    });
  } catch (error) {
    warn?.("[StackAuthStore] Failed to persist Stack tokens", error);
  }
}

export async function restoreStackTokens({
  session,
  projectId,
  fallbackCookieUrl,
  log,
  warn,
}: RestoreArgs): Promise<RestoreResult> {
  const filePath = storagePath();
  let raw: string;
  try {
    raw = await readFile(filePath, "utf8");
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
      return { restored: false, reason: "missing" };
    }
    warn?.("[StackAuthStore] Failed to read stored Stack tokens", error);
    return { restored: false, reason: "read-error" };
  }

  let parsed: StoredStackAuth;
  try {
    parsed = JSON.parse(raw) as StoredStackAuth;
  } catch (error) {
    warn?.("[StackAuthStore] Stored Stack tokens were not valid JSON", error);
    await clearStoredStackTokens({ warn });
    return { restored: false, reason: "parse-error" };
  }

  if (parsed.version !== FILE_VERSION) {
    warn?.("[StackAuthStore] Stored Stack tokens version mismatch", {
      stored: parsed.version,
      expected: FILE_VERSION,
    });
    await clearStoredStackTokens({ warn });
    return { restored: false, reason: "version-mismatch" };
  }

  if (parsed.projectId !== projectId) {
    warn?.("[StackAuthStore] Stored Stack tokens project mismatch", {
      stored: parsed.projectId,
      expected: projectId,
    });
    await clearStoredStackTokens({ warn });
    return { restored: false, reason: "project-mismatch" };
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  if (!parsed.refresh?.value || !isFiniteNumber(parsed.refresh.expiresAt)) {
    warn?.("[StackAuthStore] Stored Stack refresh token metadata invalid");
    await clearStoredStackTokens({ warn });
    return { restored: false, reason: "invalid-refresh" };
  }

  if (parsed.refresh.expiresAt <= nowSeconds + 30) {
    warn?.("[StackAuthStore] Stored refresh token expired or near expiry", {
      expiresAt: parsed.refresh.expiresAt,
      nowSeconds,
    });
    await clearStoredStackTokens({ warn });
    return { restored: false, reason: "refresh-expired" };
  }

  const cookieUrl = normalizeCookieUrl(parsed.cookieUrl, fallbackCookieUrl);
  const refreshCookieName = `stack-refresh-${projectId}`;
  const accessCookieName = "stack-access";

  const removals: Promise<unknown>[] = [];
  removals.push(session.cookies.remove(cookieUrl, refreshCookieName));
  removals.push(session.cookies.remove(cookieUrl, accessCookieName));
  await Promise.all(removals).catch(() => {
    // Removing old cookies is best effort; ignore failures.
  });

  const setters: Promise<unknown>[] = [];
  setters.push(
    session.cookies.set({
      url: cookieUrl,
      name: refreshCookieName,
      value: parsed.refresh.value,
      expirationDate: parsed.refresh.expiresAt,
      sameSite: "no_restriction",
      secure: true,
    })
  );

  const accessValid =
    parsed.access?.value &&
    isFiniteNumber(parsed.access.expiresAt) &&
    parsed.access.expiresAt > nowSeconds + 5;

  if (accessValid) {
    setters.push(
      session.cookies.set({
        url: cookieUrl,
        name: accessCookieName,
        value: parsed.access!.value,
        expirationDate: parsed.access!.expiresAt,
        sameSite: "no_restriction",
        secure: true,
      })
    );
  }

  try {
    await Promise.all(setters);
    await session.cookies.flushStore();
    log?.("[StackAuthStore] Restored Stack tokens from disk", {
      filePath,
      accessRestored: Boolean(accessValid),
      refreshExpiresAt: parsed.refresh.expiresAt,
      accessExpiresAt: parsed.access?.expiresAt ?? null,
    });
    return { restored: true };
  } catch (error) {
    warn?.("[StackAuthStore] Failed to restore Stack tokens", error);
    return { restored: false, reason: "set-error" };
  }
}

export async function clearStoredStackTokens({ warn }: ClearArgs = {}): Promise<void> {
  const filePath = storagePath();
  try {
    await rm(filePath, { force: true });
    warn?.("[StackAuthStore] Cleared stored Stack tokens", { filePath });
  } catch (error) {
    warn?.("[StackAuthStore] Failed to clear stored Stack tokens", error);
  }
}
