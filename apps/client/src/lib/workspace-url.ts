import { toProxyWorkspaceUrl } from "./toProxyWorkspaceUrl";

type VSCodeProvider = "docker" | "morph" | "daytona" | "bubblewrap" | "other" | undefined;

/**
 * Get the workspace URL with appropriate serve-web handling based on provider.
 *
 * - For Docker workspaces (provider === "docker"): Uses Docker-forwarded port directly
 * - For local workspaces (provider === "other"): Rewrites to local serve-web
 * - For Morph workspaces (provider === "morph"): Uses Morph URL directly (no rewriting needed)
 */
export function getWorkspaceUrl(
  rawWorkspaceUrl: string | null | undefined,
  provider: VSCodeProvider,
  localServeWebBaseUrl: string | null | undefined
): string | null {
  if (!rawWorkspaceUrl) {
    return null;
  }

  // Only use local serve-web for truly local workspaces (provider === "other")
  // Docker and Morph workspaces should use their URLs directly
  const shouldUseLocalServeWeb = provider === "other";
  const preferredOrigin = shouldUseLocalServeWeb ? localServeWebBaseUrl : null;

  return toProxyWorkspaceUrl(rawWorkspaceUrl, preferredOrigin);
}
