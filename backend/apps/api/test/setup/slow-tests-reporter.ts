import type { Reporter, TestCase } from "vitest/node"

/**
 * Lists every test case slower than CMUX_SLOW_TEST_MS (default 2000 ms) at the end of a run, slowest
 * first, so slow setup is fixed instead of hidden behind the suite timeout (vitest.config.ts). A case
 * over 2 s when its file runs alone (`npx vitest run test/<file>.test.ts`) has a slow part to fix:
 * per-case setup that could be shared, a fixed wait, a real timer, or a big fixture. The full parallel
 * run inflates every duration (about 9x on a 32 vCPU host), so read the list from a run of one file.
 */
export default class SlowTestsReporter implements Reporter {
  private readonly limit = Number(process.env.CMUX_SLOW_TEST_MS ?? 2000)
  private readonly slow: Array<{ ms: number; file: string; name: string }> = []

  onTestCaseResult(test: TestCase) {
    const ms = test.diagnostic()?.duration ?? 0
    if (ms > this.limit) this.slow.push({ ms: Math.round(ms), file: test.module.relativeModuleId, name: test.fullName })
  }

  onTestRunEnd() {
    if (this.slow.length === 0) return
    this.slow.sort((a, b) => b.ms - a.ms)
    const lines = this.slow.map((s) => `  ${String(s.ms).padStart(6)} ms  ${s.file} > ${s.name}`)
    console.log(`\nSlow test cases (over ${this.limit} ms; durations from a parallel run are inflated, check a file alone):\n${lines.join("\n")}\n`)
  }
}
