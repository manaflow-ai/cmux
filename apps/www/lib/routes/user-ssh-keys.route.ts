import { getConvex } from "@/lib/utils/get-convex";
import { stackServerAppJs } from "@/lib/utils/stack";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";

export const userSshKeysRouter = new OpenAPIHono();

// Response schemas
const SshKeySchema = z
  .object({
    id: z.string(),
    name: z.string(),
    fingerprint: z.string(),
    source: z.enum(["manual", "github", "local"]),
    createdAt: z.number(),
  })
  .openapi("SshKey");

const ListSshKeysResponse = z.array(SshKeySchema).openapi("ListSshKeysResponse");

const CreateSshKeyBody = z
  .object({
    publicKey: z.string(),
    name: z.string(),
  })
  .openapi("CreateSshKeyBody");

const CreateSshKeyResponse = z
  .object({
    id: z.string(),
    fingerprint: z.string(),
  })
  .openapi("CreateSshKeyResponse");

const DeleteSshKeyResponse = z
  .object({
    success: z.literal(true),
  })
  .openapi("DeleteSshKeyResponse");

const ImportGithubKeysResponse = z
  .object({
    imported: z.number(),
    keys: z.array(
      z.object({
        id: z.string(),
        fingerprint: z.string(),
      })
    ),
  })
  .openapi("ImportGithubKeysResponse");

/**
 * Compute SSH key fingerprint from a public key string.
 * Format: 'SHA256:base64...'
 */
async function computeSshFingerprint(publicKey: string): Promise<string> {
  // SSH public key format: "type base64-blob comment"
  const parts = publicKey.trim().split(/\s+/);
  if (parts.length < 2) {
    throw new Error("Invalid SSH public key format");
  }

  const keyType = parts[0];
  const keyBlob = parts[1];

  // Validate key type
  const validTypes = [
    "ssh-rsa",
    "ssh-dss",
    "ssh-ed25519",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
  ];

  if (!validTypes.includes(keyType)) {
    throw new Error(`Unsupported SSH key type: ${keyType}`);
  }

  // Decode base64 blob and compute SHA256 hash
  let binaryData: Uint8Array;
  try {
    binaryData = Uint8Array.from(atob(keyBlob), (c) => c.charCodeAt(0));
  } catch {
    throw new Error("Invalid base64 in SSH public key");
  }

  const hashBuffer = await crypto.subtle.digest("SHA-256", binaryData);
  const hashArray = new Uint8Array(hashBuffer);

  // Convert to base64 without padding (matches ssh-keygen output)
  const base64Hash = btoa(String.fromCharCode.apply(null, Array.from(hashArray))).replace(/=+$/, "");

  return `SHA256:${base64Hash}`;
}

/**
 * Validate SSH public key format.
 */
function validateSshPublicKey(publicKey: string): void {
  const parts = publicKey.trim().split(/\s+/);
  if (parts.length < 2) {
    throw new Error("Invalid SSH public key format: expected 'type base64-blob [comment]'");
  }

  const validTypes = [
    "ssh-rsa",
    "ssh-dss",
    "ssh-ed25519",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
  ];

  if (!validTypes.includes(parts[0])) {
    throw new Error(`Unsupported SSH key type: ${parts[0]}`);
  }

  // Validate base64 blob
  try {
    atob(parts[1]);
  } catch {
    throw new Error("Invalid base64 in SSH public key");
  }
}

// GET /user/ssh-keys - List all SSH keys for the authenticated user
userSshKeysRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/user/ssh-keys",
    tags: ["User SSH Keys"],
    summary: "List all SSH keys for the authenticated user",
    responses: {
      200: {
        content: {
          "application/json": {
            schema: ListSshKeysResponse,
          },
        },
        description: "List of SSH keys",
      },
      401: { description: "Unauthorized" },
      500: { description: "Failed to fetch SSH keys" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    try {
      const convex = getConvex({ accessToken });
      const keys = await convex.query(api.userSshKeys.listByUser, {});

      return c.json(
        keys.map((key) => ({
          id: key._id,
          name: key.name,
          fingerprint: key.fingerprint,
          source: key.source,
          createdAt: key.createdAt,
        })),
        200
      );
    } catch (error) {
      console.error("[user-ssh-keys] Failed to list SSH keys:", error);
      return c.text("Failed to fetch SSH keys", 500);
    }
  }
);

// POST /user/ssh-keys - Create a new SSH key
userSshKeysRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/user/ssh-keys",
    tags: ["User SSH Keys"],
    summary: "Add a new SSH key for the authenticated user",
    request: {
      body: {
        content: {
          "application/json": {
            schema: CreateSshKeyBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: CreateSshKeyResponse,
          },
        },
        description: "SSH key created",
      },
      400: { description: "Invalid SSH key format" },
      401: { description: "Unauthorized" },
      409: { description: "SSH key already exists" },
      500: { description: "Failed to create SSH key" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    const { publicKey, name } = c.req.valid("json");

    // Validate the public key format
    try {
      validateSshPublicKey(publicKey);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Invalid SSH key format";
      return c.text(message, 400);
    }

    // Compute fingerprint
    let fingerprint: string;
    try {
      fingerprint = await computeSshFingerprint(publicKey);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to compute fingerprint";
      return c.text(message, 400);
    }

    try {
      const convex = getConvex({ accessToken });
      const id = await convex.mutation(api.userSshKeys.create, {
        name,
        publicKey,
        fingerprint,
        source: "manual",
      });

      return c.json({ id, fingerprint }, 200);
    } catch (error) {
      console.error("[user-ssh-keys] Failed to create SSH key:", error);
      if (error instanceof Error && error.message.includes("already exists")) {
        return c.text("SSH key with this fingerprint already exists", 409);
      }
      return c.text("Failed to create SSH key", 500);
    }
  }
);

// DELETE /user/ssh-keys/:id - Delete an SSH key
userSshKeysRouter.openapi(
  createRoute({
    method: "delete" as const,
    path: "/user/ssh-keys/{id}",
    tags: ["User SSH Keys"],
    summary: "Delete an SSH key",
    request: {
      params: z.object({ id: z.string() }),
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: DeleteSshKeyResponse,
          },
        },
        description: "SSH key deleted",
      },
      401: { description: "Unauthorized" },
      403: { description: "Not authorized to delete this SSH key" },
      404: { description: "SSH key not found" },
      500: { description: "Failed to delete SSH key" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    const { id } = c.req.valid("param");

    try {
      const convex = getConvex({ accessToken });
      await convex.mutation(api.userSshKeys.remove, {
        id: id as Id<"userSshKeys">,
      });

      return c.json({ success: true as const }, 200);
    } catch (error) {
      console.error("[user-ssh-keys] Failed to delete SSH key:", error);
      if (error instanceof Error) {
        if (error.message.includes("not found")) {
          return c.text("SSH key not found", 404);
        }
        if (error.message.includes("Not authorized")) {
          return c.text("Not authorized to delete this SSH key", 403);
        }
      }
      return c.text("Failed to delete SSH key", 500);
    }
  }
);

// POST /user/ssh-keys/import-github - Import SSH keys from GitHub
userSshKeysRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/user/ssh-keys/import-github",
    tags: ["User SSH Keys"],
    summary: "Import SSH keys from the connected GitHub account",
    responses: {
      200: {
        content: {
          "application/json": {
            schema: ImportGithubKeysResponse,
          },
        },
        description: "GitHub SSH keys imported",
      },
      401: { description: "Unauthorized" },
      400: { description: "GitHub account not connected" },
      500: { description: "Failed to import GitHub SSH keys" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    // Get GitHub account
    const githubAccount = await user.getConnectedAccount("github");
    if (!githubAccount) {
      return c.text("GitHub account not connected", 400);
    }

    // Fetch GitHub user info to get login
    const { accessToken: githubAccessToken } = await githubAccount.getAccessToken();
    if (!githubAccessToken) {
      return c.text("Could not get GitHub access token", 400);
    }

    try {
      // First get the user's login
      const userResponse = await fetch("https://api.github.com/user", {
        headers: {
          Authorization: `Bearer ${githubAccessToken}`,
          Accept: "application/vnd.github+json",
          "X-GitHub-Api-Version": "2022-11-28",
        },
      });

      if (!userResponse.ok) {
        console.error(
          "[user-ssh-keys] GitHub user API error:",
          userResponse.status,
          await userResponse.text()
        );
        return c.text("Failed to get GitHub user info", 500);
      }

      const githubUser = (await userResponse.json()) as { login: string };
      const username = githubUser.login;

      // Fetch public SSH keys from GitHub
      const keysResponse = await fetch(
        `https://api.github.com/users/${username}/keys`,
        {
          headers: {
            Accept: "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
          },
        }
      );

      if (!keysResponse.ok) {
        console.error(
          "[user-ssh-keys] GitHub keys API error:",
          keysResponse.status,
          await keysResponse.text()
        );
        return c.text("Failed to fetch GitHub SSH keys", 500);
      }

      const githubKeys = (await keysResponse.json()) as Array<{
        id: number;
        key: string;
      }>;

      if (githubKeys.length === 0) {
        return c.json({ imported: 0, keys: [] }, 200);
      }

      const convex = getConvex({ accessToken });
      const importedKeys: Array<{ id: string; fingerprint: string }> = [];

      for (const githubKey of githubKeys) {
        try {
          const fingerprint = await computeSshFingerprint(githubKey.key);

          // Generate a name from the key comment or use GitHub key ID
          const keyParts = githubKey.key.trim().split(/\s+/);
          const comment = keyParts.length > 2 ? keyParts.slice(2).join(" ") : null;
          const name = comment || `GitHub Key ${githubKey.id}`;

          const id = await convex.mutation(api.userSshKeys.create, {
            name,
            publicKey: githubKey.key,
            fingerprint,
            source: "github",
          });

          importedKeys.push({ id, fingerprint });
        } catch (error) {
          // Skip keys that already exist or have invalid format
          console.log(
            `[user-ssh-keys] Skipping GitHub key ${githubKey.id}:`,
            error instanceof Error ? error.message : "Unknown error"
          );
        }
      }

      return c.json(
        {
          imported: importedKeys.length,
          keys: importedKeys,
        },
        200
      );
    } catch (error) {
      console.error("[user-ssh-keys] Failed to import GitHub SSH keys:", error);
      return c.text("Failed to import GitHub SSH keys", 500);
    }
  }
);
