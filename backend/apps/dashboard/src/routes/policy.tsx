import { createFileRoute, Link } from "@tanstack/react-router"
import { useLoad } from "../lib/hooks"
import { useTeamApi } from "../lib/team-api"
import { newKey, setSignedIn, useSignedIn } from "../lib/session"
import { EnrollmentTokens } from "./-enrollment"
import { PolicyView, type PolicyVersion, type TeamPolicy } from "./-policy-view"

export const Route = createFileRoute("/policy")({ component: Policy })

function Policy() {
  const signedIn = useSignedIn()
  const { read, mutate, team } = useTeamApi()
  const loaded = useLoad<{ policy: TeamPolicy; history: Array<PolicyVersion> | null }>(signedIn ? `policy:${team ?? "personal"}` : null, async () => {
    const r = await read({ data: { op: "team.policy.get", params: {} } })
    if (r.status === 401) setSignedIn(false)
    if (r.status !== 200) throw new Error(`team.policy.get failed: ${r.status} (open Devices once to create your personal team)`)
    // History is admins only; members get 403 and see no history section.
    const h = await read({ data: { op: "team.policy.history", params: { limit: 20 } } })
    const value = r.body.value as unknown as { policy: TeamPolicy }
    return { policy: value.policy, history: h.status === 200 ? ((h.body.value as unknown as { versions: Array<PolicyVersion> }).versions ?? []) : null }
  })
  if (signedIn === false)
    return (
      <p>
        <Link to="/">Sign in</Link> to see your team policy.
      </p>
    )
  const policy = loaded.data?.policy
  const isAdmin = loaded.data?.history !== null && loaded.data !== undefined
  const failed = (r: { status: number; body: { error?: { code?: string; message?: string } } }) => `${r.body.error?.code ?? r.status}: ${r.body.error?.message ?? "failed"}`

  return (
    <>
      <PolicyView
        policy={policy}
        history={loaded.data?.history ?? null}
        isAdmin={isAdmin}
        onSave={async (changes, reason) => {
          if (!policy) return "not loaded"
          const r = await mutate({
            data: { op: "team.policy.update", params: { changes, expected_version: policy.version, ...(reason ? { reason } : {}) }, idempotency_key: newKey() }
          })
          if (!r.body.ok) return failed(r)
          loaded.reload()
          return null
        }}
        onRollback={async (version) => {
          if (!policy) return "not loaded"
          const r = await mutate({ data: { op: "team.policy.rollback", params: { version, expected_version: policy.version }, idempotency_key: newKey() } })
          if (!r.body.ok) return failed(r)
          loaded.reload()
          return null
        }}
      >
        {isAdmin ? <EnrollmentTokens /> : null}
      </PolicyView>
      {loaded.error ? <p className="error">{loaded.error}</p> : null}
      {loaded.loading ? <p className="muted">Loading</p> : null}
    </>
  )
}
