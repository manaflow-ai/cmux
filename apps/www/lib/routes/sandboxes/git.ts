import { fetchGithubUserInfoForRequest } from "@/lib/utils/githubUserInfo";
import { api } from "@cmux/convex/api";

import type { MorphCloudClient } from "morphcloud";

import type { ConvexClient } from "./snapshot";
import { singleQuote } from "./shell";

export type MorphInstance = Awaited<
  ReturnType<MorphCloudClient["instances"]["start"]>
>;

interface UserSshKey {
  publicKey: string;
  name: string;
  fingerprint: string;
  source: "manual" | "github" | "local";
}

export const fetchGitIdentityInputs = (
  convex: ConvexClient,
  githubAccessToken: string
) =>
  Promise.all([
    convex.query(api.users.getCurrentBasic, {}),
    fetchGithubUserInfoForRequest(githubAccessToken),
  ] as const);

export const configureGitIdentity = async (
  instance: MorphInstance,
  identity: { name: string; email: string }
) => {
  const gitCfgRes = await instance.exec(
    `bash -lc "git config --global user.name ${singleQuote(identity.name)} && git config --global user.email ${singleQuote(identity.email)} && git config --global init.defaultBranch main && git config --global push.autoSetupRemote true && echo NAME:$(git config --global --get user.name) && echo EMAIL:$(git config --global --get user.email) || true"`
  );
  if (gitCfgRes.exit_code !== 0) {
    console.error(
      `[sandboxes.start] GIT CONFIG: Failed to configure git identity, exit=${gitCfgRes.exit_code}`
    );
  }
};

export const configureGithubAccess = async (
  instance: MorphInstance,
  token: string,
  maxRetries = 5
) => {
  let lastError: Error | undefined;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      const ghAuthRes = await instance.exec(
        `bash -lc "printf %s ${singleQuote(token)} | gh auth login --with-token && gh auth setup-git 2>&1"`
      );

      if (ghAuthRes.exit_code === 0) {
        return;
      }

      const errorMessage =
        ghAuthRes.stderr || ghAuthRes.stdout || "Unknown error";
      const maskedError = errorMessage.replace(/:[^@]*@/g, ":***@");
      lastError = new Error(`GitHub auth failed: ${maskedError.slice(0, 500)}`);

      console.error(
        `[sandboxes.start] GIT AUTH: Attempt ${attempt}/${maxRetries} failed: exit=${ghAuthRes.exit_code} stderr=${maskedError.slice(0, 200)}`
      );

      if (attempt < maxRetries) {
        const delay = Math.min(1000 * Math.pow(2, attempt - 1), 5000);
        await new Promise((resolve) => setTimeout(resolve, delay));
      }
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      console.error(
        `[sandboxes.start] GIT AUTH: Attempt ${attempt}/${maxRetries} threw error:`,
        error
      );

      if (attempt < maxRetries) {
        const delay = Math.min(1000 * Math.pow(2, attempt - 1), 5000);
        await new Promise((resolve) => setTimeout(resolve, delay));
      }
    }
  }

  console.error(
    `[sandboxes.start] GIT AUTH: GitHub authentication failed after ${maxRetries} attempts`
  );
  throw new Error(
    `GitHub authentication failed after ${maxRetries} attempts: ${lastError?.message || "Unknown error"}`
  );
};

/**
 * Injects the user's registered SSH public keys into a Morph instance.
 * Creates /root/.ssh/authorized_keys with proper permissions.
 *
 * @returns The number of keys injected
 */
export const injectUserSshKeys = async (
  instance: MorphInstance,
  convex: ConvexClient
): Promise<number> => {
  const sshKeys = (await convex.query(
    api.userSshKeys.listByUser,
    {}
  )) as unknown as UserSshKey[];

  if (sshKeys.length === 0) {
    console.log("[sandboxes.start] SSH KEYS: No SSH keys to inject");
    return 0;
  }

  const publicKeys = sshKeys.map((key) => key.publicKey.trim()).join("\n");

  // Create .ssh directory with proper permissions and write authorized_keys
  const setupCmd = await instance.exec(
    `bash -lc "mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat > /root/.ssh/authorized_keys << 'EOF'
${publicKeys}
EOF
chmod 600 /root/.ssh/authorized_keys && echo 'SSH keys injected: '$(wc -l < /root/.ssh/authorized_keys)"`
  );

  if (setupCmd.exit_code !== 0) {
    console.error(
      `[sandboxes.start] SSH KEYS: Failed to inject SSH keys, exit=${setupCmd.exit_code}, stderr=${setupCmd.stderr || setupCmd.stdout}`
    );
    throw new Error(
      `Failed to inject SSH keys: ${setupCmd.stderr || setupCmd.stdout}`
    );
  }

  console.log(
    `[sandboxes.start] SSH KEYS: Injected ${sshKeys.length} SSH key(s)`
  );
  return sshKeys.length;
};
