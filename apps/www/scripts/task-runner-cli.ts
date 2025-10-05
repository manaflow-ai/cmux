import { __TEST_INTERNAL_ONLY_GET_STACK_TOKENS } from "@/lib/test-utils/__TEST_INTERNAL_ONLY_GET_STACK_TOKENS";
import { __TEST_INTERNAL_ONLY_MORPH_CLIENT } from "@/lib/test-utils/__TEST_INTERNAL_ONLY_MORPH_CLIENT";
import { honoTestFetch } from "@/lib/utils/hono-test-fetch";
import { getConvex } from "@/lib/utils/get-convex";
import { api } from "@cmux/convex/api";
import type { Doc, Id } from "@cmux/convex/dataModel";
import { postApiSandboxesStart } from "@cmux/www-openapi-client";
import { createClient } from "@cmux/www-openapi-client/client";
import { typedZid } from "@cmux/shared/utils/typed-zid";

const DEFAULT_USER_ID = "487b5ddc-0da0-4f12-8834-f452863a83f5";
const DEFAULT_COMMAND = "bash -lc \"pwd\"";

const fetchCompat: typeof fetch = Object.assign(
  ((input: RequestInfo | URL, init?: RequestInit) =>
    honoTestFetch(input, init)) as typeof fetch,
  {
    preconnect: async () => {}
  }
);

const apiClient = createClient({
  fetch: fetchCompat,
  baseUrl: "http://localhost"
});

type ResolvedEnvironment = {
  environment: Doc<"environments">;
  teamSlugOrId: string;
};

type StartArgs = {
  environmentId: Id<"environments">;
  prompt: string;
  teamSlugOrId?: string;
  userId: string;
};

type ExecArgs = {
  instanceId: string;
  command: string;
  userId: string;
};

function parseStartArgs(argv: string[]): StartArgs {
  let environmentInput: string | undefined;
  let prompt: string | undefined;
  let teamSlugOrId: string | undefined;
  let userId = DEFAULT_USER_ID;

  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];
    if (current === "--environment" || current === "-e") {
      environmentInput = argv[index + 1];
      index += 1;
      continue;
    }
    if (current === "--prompt" || current === "-p") {
      prompt = argv[index + 1];
      index += 1;
      continue;
    }
    if (current === "--team" || current === "-t") {
      teamSlugOrId = argv[index + 1];
      index += 1;
      continue;
    }
    if (current === "--user" || current === "-u") {
      userId = argv[index + 1] ?? DEFAULT_USER_ID;
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${current}`);
  }

  if (!environmentInput) {
    throw new Error("--environment <id> is required");
  }
  if (!prompt) {
    throw new Error("--prompt <text> is required");
  }

  const environmentId = typedZid("environments").parse(environmentInput);

  return {
    environmentId,
    prompt,
    teamSlugOrId,
    userId
  };
}

function parseExecArgs(argv: string[]): ExecArgs {
  let instanceId: string | undefined;
  let command = DEFAULT_COMMAND;
  let userId = DEFAULT_USER_ID;

  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];
    if (current === "--instance" || current === "-i") {
      instanceId = argv[index + 1];
      index += 1;
      continue;
    }
    if (current === "--command" || current === "-c") {
      command = argv[index + 1] ?? DEFAULT_COMMAND;
      index += 1;
      continue;
    }
    if (current === "--user" || current === "-u") {
      userId = argv[index + 1] ?? DEFAULT_USER_ID;
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${current}`);
  }

  if (!instanceId) {
    throw new Error("--instance <id> is required");
  }

  return {
    instanceId,
    command,
    userId
  };
}

async function resolveTeamAndEnvironment(
  convex: ReturnType<typeof getConvex>,
  environmentId: Id<"environments">,
  explicitTeamSlugOrId?: string
): Promise<ResolvedEnvironment> {
  if (explicitTeamSlugOrId) {
    const environment = await convex.query(api.environments.get, {
      teamSlugOrId: explicitTeamSlugOrId,
      id: environmentId
    });
    if (!environment) {
      throw new Error(
        `Environment ${environmentId} not found for team ${explicitTeamSlugOrId}`
      );
    }
    return { environment, teamSlugOrId: explicitTeamSlugOrId };
  }

  const memberships = await convex.query(api.teams.listTeamMemberships, {});

  for (const membership of memberships) {
    const team = membership.team;
    if (!team) {
      continue;
    }
    const candidateTeam = team.slug ?? team.teamId;
    const environment = await convex.query(api.environments.get, {
      teamSlugOrId: candidateTeam,
      id: environmentId
    });
    if (environment) {
      return { environment, teamSlugOrId: candidateTeam };
    }
  }

  throw new Error(
    `Unable to locate environment ${environmentId} in any accessible team`
  );
}

async function runStartCommand(args: StartArgs) {
  console.log("Fetching Stack tokens...");
  const tokens = await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS(args.userId);

  console.log("Initialising Convex client...");
  const convex = getConvex({ accessToken: tokens.accessToken });

  console.log("Resolving environment and team...");
  const { environment, teamSlugOrId } = await resolveTeamAndEnvironment(
    convex,
    args.environmentId,
    args.teamSlugOrId
  );

  const taskText = args.prompt;
  const projectFullName = environment.selectedRepos?.[0] ?? undefined;

  console.log("Creating task...");
  const taskId = await convex.mutation(api.tasks.create, {
    teamSlugOrId,
    text: taskText,
    description: taskText,
    projectFullName,
    environmentId: args.environmentId
  });

  console.log(`Task created: ${taskId}`);

  console.log("Creating task run...");
  const { taskRunId, jwt } = await convex.mutation(api.taskRuns.create, {
    teamSlugOrId,
    taskId,
    prompt: args.prompt,
    agentName: "task-cli",
    environmentId: args.environmentId
  });

  console.log(`Task run created: ${taskRunId}`);

  console.log("Starting sandbox via Hono API...");
  const sandboxResponse = await postApiSandboxesStart({
    client: apiClient,
    headers: { "x-stack-auth": JSON.stringify(tokens) },
    body: {
      teamSlugOrId,
      environmentId: args.environmentId,
      taskRunId,
      taskRunJwt: jwt,
      metadata: {
        caller: "task-cli"
      }
    }
  });

  if (sandboxResponse.response.status !== 200 || !sandboxResponse.data) {
    const message = sandboxResponse.error
      ? String(sandboxResponse.error)
      : `Sandbox start failed with status ${sandboxResponse.response.status}`;
    throw new Error(message);
  }

  const { instanceId, workerUrl, vscodeUrl } = sandboxResponse.data;
  console.log("Sandbox started", { instanceId, workerUrl, vscodeUrl });

  const summary = {
    taskId,
    taskRunId,
    taskRunJwt: jwt,
    teamSlugOrId,
    environmentId: args.environmentId,
    instanceId,
    workerUrl,
    vscodeUrl
  };

  console.log("Start summary =>", JSON.stringify(summary, null, 2));
  console.log(
    `bun run --env-file ./.env apps/www/scripts/task-runner-cli.ts exec --instance ${instanceId} --command "bash -lc 'ls /root'"`
  );
}

async function runExecCommand(args: ExecArgs) {
  console.log("Fetching Stack tokens for exec user...");
  await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS(args.userId);

  console.log(`Fetching Morph instance ${args.instanceId}...`);
  const instance = await __TEST_INTERNAL_ONLY_MORPH_CLIENT.instances.get({
    instanceId: args.instanceId
  });

  console.log(`Executing command in Morph instance: ${args.command}`);
  const execResult = await instance.exec(args.command);

  console.log("Command completed", {
    exitCode: execResult.exit_code,
    stdout: execResult.stdout,
    stderr: execResult.stderr
  });
}

async function main() {
  const [command, ...argv] = process.argv.slice(2);
  if (!command) {
    throw new Error("Expected first argument to be 'start' or 'exec'");
  }

  if (command === "start") {
    const args = parseStartArgs(argv);
    await runStartCommand(args);
    return;
  }

  if (command === "exec") {
    const args = parseExecArgs(argv);
    await runExecCommand(args);
    return;
  }

  throw new Error(`Unknown command: ${command}`);
}

main().catch((error) => {
  console.error("task-runner-cli failed", error);
  process.exitCode = 1;
});
