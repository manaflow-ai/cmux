import { type FrameworkPreset } from "@/components/preview/preview-configure-client";
import { createGitHubClient } from "@/lib/github/octokit";

type PackageJson = {
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
  optionalDependencies?: Record<string, string>;
  peerDependencies?: Record<string, string>;
  scripts?: Record<string, string>;
};

type PackageJsonWithPath = {
  path: string;
  json: PackageJson;
};

type DetectorRule = {
  path?: string;
  matchPackage?: string;
  matchContent?: RegExp;
  matchScript?: RegExp;
};

type FrameworkDefinition = {
  preset: FrameworkPreset;
  detectors: {
    every?: DetectorRule[];
    some?: DetectorRule[];
  };
  supersedes?: FrameworkPreset[];
};

type DetectionContext = {
  owner: string;
  name: string;
  octokit: ReturnType<typeof createGitHubClient>;
  filePaths: Set<string> | null;
  normalizedFilePaths: Set<string> | null;
  packageJsons: PackageJsonWithPath[];
  fileExistsCache: Map<string, boolean>;
  fileContentCache: Map<string, string | null>;
};

type FrameworkMatch = {
  definition: FrameworkDefinition;
};

const MAX_PACKAGE_JSON_FILES = 20;
const MIN_PACKAGE_JSONS_BEFORE_FALLBACK = 3;
const FALLBACK_PACKAGE_JSON_PATHS = [
  "app/package.json",
  "apps/web/package.json",
  "apps/app/package.json",
  "apps/site/package.json",
  "apps/client/package.json",
  "packages/web/package.json",
  "packages/app/package.json",
  "packages/site/package.json",
  "frontend/package.json",
  "web/package.json",
  "site/package.json",
  "client/package.json",
  "www/package.json",
];
const COMMON_PACKAGE_PARENT_HINTS = [
  "apps",
  "app",
  "packages",
  "frontend",
  "web",
  "site",
  "client",
  "services",
  "examples",
  "www",
];

// Heuristics mirror Vercel's detector list: prefer dependency matches, then config files, then scripts.
const FRAMEWORK_DEFINITIONS: FrameworkDefinition[] = [
  {
    preset: "next",
    detectors: {
      some: [
        { matchPackage: "next" },
        { path: "next.config.js" },
        { path: "next.config.ts" },
        { path: "next.config.mjs" },
        { matchScript: /\bnext\b/i },
      ],
    },
    supersedes: ["vite"],
  },
  {
    preset: "nuxt",
    detectors: {
      some: [
        { matchPackage: "nuxt" },
        { matchPackage: "nuxt3" },
        { matchPackage: "nuxt-edge" },
        { matchPackage: "nuxt-nightly" },
        { path: "nuxt.config.js" },
        { path: "nuxt.config.ts" },
        { path: "nuxt.config.mjs" },
        { matchScript: /\bnuxt\b/i },
      ],
    },
    supersedes: ["vite"],
  },
  {
    preset: "remix",
    detectors: {
      some: [
        { matchPackage: "@remix-run/dev" },
        { matchPackage: "@remix-run/node" },
        { matchPackage: "@remix-run/serve" },
        { path: "remix.config.js" },
        { path: "remix.config.ts" },
        { path: "remix.config.mjs" },
        { path: "remix.config.cjs" },
        { matchScript: /\bremix\b/i },
      ],
    },
    supersedes: ["vite"],
  },
  {
    preset: "sveltekit",
    detectors: {
      some: [
        { matchPackage: "@sveltejs/kit" },
        { path: "svelte.config.js" },
        { path: "svelte.config.ts" },
        { path: "svelte.config.mjs" },
        { matchScript: /\bsvelte-?kit\b/i },
      ],
    },
    supersedes: ["vite"],
  },
  {
    preset: "angular",
    detectors: {
      some: [
        { matchPackage: "@angular/cli" },
        { matchPackage: "@angular/core" },
        { path: "angular.json" },
        { matchScript: /\bng (serve|build)/i },
      ],
    },
  },
  {
    preset: "cra",
    detectors: {
      some: [
        { matchPackage: "react-scripts" },
        { matchPackage: "react-dev-utils" },
        { matchScript: /\breact-scripts\b/i },
      ],
    },
  },
  {
    preset: "vue",
    detectors: {
      some: [
        { matchPackage: "@vue/cli-service" },
        { path: "vue.config.js" },
        { path: "vue.config.ts" },
        { path: "vue.config.mjs" },
        { matchScript: /\bvue-cli-service\b/i },
      ],
    },
    supersedes: ["vite"],
  },
  {
    preset: "vite",
    detectors: {
      some: [
        { matchPackage: "vite" },
        { path: "vite.config.js" },
        { path: "vite.config.ts" },
        { path: "vite.config.mjs" },
        { matchScript: /\bvite\b/i },
      ],
    },
  },
];

export async function detectFrameworkPreset(repoFullName: string): Promise<FrameworkPreset> {
  const [owner, name] = repoFullName.split("/");
  if (!owner || !name) {
    return "other";
  }

  const octokit = createGitHubClient(undefined, { useTokenRotation: true });
  const context = await buildDetectionContext(octokit, owner, name);

  const matches: FrameworkMatch[] = [];
  for (const definition of FRAMEWORK_DEFINITIONS) {
    const hit = await definitionMatches(definition, context);
    if (hit) {
      matches.push({ definition });
    }
  }

  const resolvedMatches = applySupersedes(matches);
  if (resolvedMatches.length === 0) {
    return "other";
  }

  return resolvedMatches[0]?.definition.preset ?? "other";
}

async function buildDetectionContext(
  octokit: ReturnType<typeof createGitHubClient>,
  owner: string,
  name: string
): Promise<DetectionContext> {
  const treeSnapshot = await fetchRepoTree(octokit, owner, name);
  const packageJsonPaths = treeSnapshot?.packageJsonPaths ?? ["package.json"];
  const packageJsons = await loadPackageJsons(
    octokit,
    owner,
    name,
    packageJsonPaths,
    !treeSnapshot || treeSnapshot.truncated
  );

  return {
    owner,
    name,
    octokit,
    filePaths: treeSnapshot?.filePaths ?? null,
    normalizedFilePaths: treeSnapshot?.normalizedFilePaths ?? null,
    packageJsons,
    fileExistsCache: new Map<string, boolean>(),
    fileContentCache: new Map<string, string | null>(),
  };
}

async function fetchRepoTree(
  octokit: ReturnType<typeof createGitHubClient>,
  owner: string,
  name: string
): Promise<{
  filePaths: Set<string>;
  normalizedFilePaths: Set<string>;
  packageJsonPaths: string[];
  truncated: boolean;
} | null> {
  try {
    const repo = await octokit.request("GET /repos/{owner}/{repo}", { owner, repo: name });
    const defaultBranch = repo.data.default_branch ?? "main";

    const tree = await octokit.request("GET /repos/{owner}/{repo}/git/trees/{tree_sha}", {
      owner,
      repo: name,
      tree_sha: defaultBranch,
      recursive: "1",
    });

    const paths = new Set<string>();
    const normalized = new Set<string>();
    const packageJsonPaths: string[] = [];

    const entries = Array.isArray(tree.data.tree) ? tree.data.tree : [];
    for (const entry of entries) {
      if (!entry?.path || entry.type !== "blob") continue;
      paths.add(entry.path);
      normalized.add(entry.path.toLowerCase());
      if (entry.path.toLowerCase().endsWith("package.json")) {
        packageJsonPaths.push(entry.path);
      }
    }

    if (packageJsonPaths.length === 0) {
      packageJsonPaths.push("package.json");
    }

    return {
      filePaths: paths,
      normalizedFilePaths: normalized,
      packageJsonPaths,
      truncated: Boolean((tree.data as { truncated?: boolean }).truncated),
    };
  } catch (error) {
    console.error("Failed to fetch repository tree", { owner, name, error });
    return null;
  }
}

async function loadPackageJsons(
  octokit: ReturnType<typeof createGitHubClient>,
  owner: string,
  name: string,
  packageJsonPaths: string[],
  includeFallbackCandidates: boolean
): Promise<PackageJsonWithPath[]> {
  const sortedPaths = prioritizePackageJsonPaths([...new Set(packageJsonPaths)]).slice(0, MAX_PACKAGE_JSON_FILES);
  const seenPaths = new Set(sortedPaths);

  const packages: PackageJsonWithPath[] = [];
  for (const path of sortedPaths) {
    const pkg = await fetchPackageJson(octokit, owner, name, path);
    if (pkg) {
      packages.push({ path, json: pkg });
    }
  }

  // If nothing could be fetched, still try the root package.json once more as a fallback.
  if (packages.length === 0 && !seenPaths.has("package.json")) {
    const fallbackRoot = await fetchPackageJson(octokit, owner, name, "package.json");
    if (fallbackRoot) {
      packages.push({ path: "package.json", json: fallbackRoot });
    }
  }

  const shouldTryFallbackCandidates =
    packages.length === 0 || (includeFallbackCandidates && packages.length < MIN_PACKAGE_JSONS_BEFORE_FALLBACK);

  if (shouldTryFallbackCandidates) {
    for (const candidate of FALLBACK_PACKAGE_JSON_PATHS) {
      if (packages.length >= MAX_PACKAGE_JSON_FILES) {
        break;
      }
      if (seenPaths.has(candidate)) {
        continue;
      }
      const pkg = await fetchPackageJson(octokit, owner, name, candidate);
      if (pkg) {
        packages.push({ path: candidate, json: pkg });
      }
    }
  }

  return packages;
}

function prioritizePackageJsonPaths(paths: string[]): string[] {
  return paths.sort((a, b) => packageJsonScore(a) - packageJsonScore(b));
}

function packageJsonScore(path: string): number {
  const normalized = path.toLowerCase();
  if (normalized === "package.json") {
    return -1;
  }

  const segments = normalized.split("/");
  const depth = segments.length - 1;
  const parent = segments.length > 1 ? segments[segments.length - 2] : "";
  const hintIndex = COMMON_PACKAGE_PARENT_HINTS.findIndex(
    (hint) => normalized.startsWith(`${hint}/`) || normalized.includes(`/${hint}/`) || parent === hint
  );
  const hintScore = hintIndex >= 0 ? hintIndex : COMMON_PACKAGE_PARENT_HINTS.length;

  return depth + hintScore * 0.1;
}

async function definitionMatches(definition: FrameworkDefinition, context: DetectionContext): Promise<boolean> {
  const { every = [], some = [] } = definition.detectors;

  for (const rule of every) {
    const matches = await ruleMatches(rule, context);
    if (!matches) {
      return false;
    }
  }

  if (some.length === 0) {
    return true;
  }

  for (const rule of some) {
    if (await ruleMatches(rule, context)) {
      return true;
    }
  }

  return false;
}

async function ruleMatches(rule: DetectorRule, context: DetectionContext): Promise<boolean> {
  if (rule.matchPackage) {
    const hasPackage = context.packageJsons.some((pkg) =>
      packageHasDependency(pkg.json, rule.matchPackage as string)
    );
    if (hasPackage) {
      return true;
    }
  }

  if (rule.matchScript) {
    const hasScriptMatch = context.packageJsons.some((pkg) =>
      packageHasScript(pkg.json, rule.matchScript as RegExp)
    );
    if (hasScriptMatch) {
      return true;
    }
  }

  if (rule.path) {
    const exists = await hasPath(rule.path, context);
    if (!exists) {
      return false;
    }

    if (rule.matchContent) {
      const content = await readFileWithCache(rule.path, context);
      return Boolean(content && rule.matchContent.test(content));
    }

    return true;
  }

  if (rule.matchContent) {
    const rootPackage = context.packageJsons.find((pkg) => pkg.path === "package.json");
    if (!rootPackage) {
      return false;
    }

    const serialized = JSON.stringify(rootPackage.json);
    return rule.matchContent.test(serialized);
  }

  return false;
}

async function hasPath(path: string, context: DetectionContext): Promise<boolean> {
  const normalized = path.toLowerCase();
  if (context.normalizedFilePaths && context.normalizedFilePaths.has(normalized)) {
    return true;
  }

  if (context.fileExistsCache.has(normalized)) {
    return context.fileExistsCache.get(normalized) as boolean;
  }

  const exists = await repoFileExists(context.octokit, context.owner, context.name, path);
  context.fileExistsCache.set(normalized, exists);
  return exists;
}

async function readFileWithCache(path: string, context: DetectionContext): Promise<string | null> {
  if (context.fileContentCache.has(path)) {
    return context.fileContentCache.get(path) ?? null;
  }

  const content = await readRepoFile(context.octokit, context.owner, context.name, path);
  context.fileContentCache.set(path, content);
  return content;
}

async function fetchPackageJson(
  octokit: ReturnType<typeof createGitHubClient>,
  owner: string,
  name: string,
  path: string
): Promise<PackageJson | null> {
  const content = await readRepoFile(octokit, owner, name, path);
  if (!content) {
    return null;
  }

  try {
    return JSON.parse(content) as PackageJson;
  } catch (error) {
    console.error("Failed to parse package.json", { owner, name, path, error });
    return null;
  }
}

async function readRepoFile(
  octokit: ReturnType<typeof createGitHubClient>,
  owner: string,
  name: string,
  path: string
): Promise<string | null> {
  try {
    const res = await octokit.request("GET /repos/{owner}/{repo}/contents/{path}", {
      owner,
      repo: name,
      path,
    });

    if (!res.data || Array.isArray(res.data) || !("content" in res.data)) {
      return null;
    }

    const data = res.data as { content?: string };
    if (!data.content) {
      return null;
    }

    return Buffer.from(data.content, "base64").toString("utf-8");
  } catch (error) {
    const status = typeof error === "object" && error && "status" in error ? (error as { status?: number }).status : null;
    if (status !== 404) {
      console.error("Failed to read repository file", { owner, name, path, error });
    }
    return null;
  }
}

async function repoFileExists(
  octokit: ReturnType<typeof createGitHubClient>,
  owner: string,
  name: string,
  path: string
): Promise<boolean> {
  try {
    await octokit.request("GET /repos/{owner}/{repo}/contents/{path}", {
      owner,
      repo: name,
      path,
    });
    return true;
  } catch {
    return false;
  }
}

function packageHasDependency(pkg: PackageJson, dependency: string): boolean {
  const groups = [
    pkg.dependencies,
    pkg.devDependencies,
    pkg.peerDependencies,
    pkg.optionalDependencies,
  ];

  return groups.some((group) => Boolean(group && dependency in group));
}

function packageHasScript(pkg: PackageJson, scriptMatcher: RegExp): boolean {
  return Object.values(pkg.scripts ?? {}).some((script) => scriptMatcher.test(script));
}

function applySupersedes(matches: FrameworkMatch[]): FrameworkMatch[] {
  const result = [...matches];
  for (const match of matches) {
    if (!match.definition.supersedes) {
      continue;
    }

    for (const superseded of match.definition.supersedes) {
      const index = result.findIndex((candidate) => candidate.definition.preset === superseded);
      if (index >= 0) {
        result.splice(index, 1);
      }
    }
  }

  return result;
}
