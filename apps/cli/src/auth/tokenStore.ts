import { secrets } from "bun";

const secretService = "com.cmux.cli";

const secretNameForProject = (projectId: string): string =>
  `stack-refresh-${projectId}`;

export async function loadSavedRefreshToken(
  projectId: string,
): Promise<string | null> {
  const secretName = secretNameForProject(projectId);

  try {
    const value = await secrets.get({
      service: secretService,
      name: secretName,
    });
    if (value && value.trim().length > 0) {
      return value;
    }
  } catch {
    // If secret retrieval fails (unsupported platform, etc.), treat as missing.
  }

  return null;
}

export async function persistRefreshToken(
  projectId: string,
  refreshToken: string,
): Promise<void> {
  await secrets.set({
    service: secretService,
    name: secretNameForProject(projectId),
    value: refreshToken,
  });
}

export async function clearStoredRefreshToken(
  projectId: string,
): Promise<void> {
  await secrets.delete({
    service: secretService,
    name: secretNameForProject(projectId),
  });
}
