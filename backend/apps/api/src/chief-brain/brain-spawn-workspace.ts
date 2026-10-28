/**
 * A cloud workspace for a spawned child (a655): the Chief's VM (its online sandbox hand) makes the
 * workspace with the cmux CLI, and `spawn` links it in its reply as `cmux://workspace/ws_…`. The
 * hands port is a seam so the test needs no hand; `spawnHost` wires the real hands.
 */

export interface WorkspaceHands {
  readonly list: () => Promise<ReadonlyArray<{ hand: string; name: string; online: boolean; sandbox?: boolean }>>
  readonly exec: (hand: string, argv: ReadonlyArray<string>) => Promise<{ exitCode: number; stdout: string; stderr: string }>
}

export type OpenedWorkspace = { readonly ok: true; readonly ws: string; readonly machine: string } | { readonly ok: false; readonly reason: string }

const WS_ID = /\bws_[A-Za-z0-9]+/

/** Makes workspace `name` on the Chief's online sandbox hand. Never throws: a failure is a reason. */
export const openCloudWorkspace = async (hands: WorkspaceHands, name: string): Promise<OpenedWorkspace> => {
  try {
    const sb = (await hands.list()).find((h) => h.sandbox && h.online)
    if (!sb) return { ok: false, reason: "the Chief has no online cloud VM" }
    const r = await hands.exec(sb.hand, ["cmux", "--json", "workspace", "create", "--name", name.slice(0, 60), "--empty"])
    if (r.exitCode !== 0) return { ok: false, reason: `cmux workspace create failed on ${sb.name}: ${(r.stderr || r.stdout).trim().slice(-120)}` }
    const ws = WS_ID.exec(r.stdout)?.[0]
    return ws ? { ok: true, ws, machine: sb.name } : { ok: false, reason: `${sb.name} printed no workspace id` }
  } catch (e) {
    return { ok: false, reason: e instanceof Error ? e.message : String(e) }
  }
}

/** The line `spawn` returns for one child: a link, or why there is no workspace. */
export const workspaceNote = (r: OpenedWorkspace) => (r.ok ? `[workspace](cmux://workspace/${r.ws}) on ${r.machine}` : `no workspace (${r.reason})`)
