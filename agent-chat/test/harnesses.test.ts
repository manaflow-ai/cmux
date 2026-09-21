import { test, expect } from "bun:test";
import { discoverHarnesses } from "../harnesses";

test("discovers project harnesses with evidence and benefits", () => {
  const project = "/repo/project";
  const home = "/home/tester";
  const paths = new Set([
    `${project}/.opencode/oh-my-openagent.jsonc`,
    `${home}/.omp`,
  ]);
  const found = discoverHarnesses({
    cwd: project,
    home,
    exists: (path) => paths.has(path),
    which: () => undefined,
  });

  expect(found.map((entry) => entry.id)).toEqual(["oh-my-openagent", "oh-my-pi"]);
  expect(found[0]).toMatchObject({
    installed: true,
    provider: "opencode",
    priority: 0,
    evidence: "found .opencode/oh-my-openagent.jsonc",
  });
  expect(found[0]?.reason).toContain("parallel specialists");
  expect(found[0]?.tags).toContain("teams");
});

test("does not claim a workflow without command or config evidence", () => {
  expect(discoverHarnesses({
    cwd: "/repo/project",
    home: "/home/tester",
    exists: () => false,
    which: () => undefined,
  })).toEqual([]);
});

