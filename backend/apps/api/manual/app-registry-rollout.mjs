import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { unstable_readConfig } from "wrangler"

// Run manually on a Freestyle VM from backend/apps/api:
// node manual/app-registry-rollout.mjs
// Use Wrangler's resolved environment, including its binding inheritance rules.
// This is intentionally outside the CI test suite until production promotion.
const config = fileURLToPath(new URL("../wrangler.jsonc", import.meta.url))
for (const environment of ["production", "development", "staging"]) {
  const resolved = unstable_readConfig({ config, env: environment })
  const bindsRegistry = resolved.durable_objects.bindings.some(
    (binding) => binding.name === "APP_REGISTRY_DO" || binding.class_name === "AppRegistryDO",
  )
  const createsRegistry = resolved.migrations.some(
    (migration) => [...(migration.new_classes ?? []), ...(migration.new_sqlite_classes ?? [])].includes("AppRegistryDO"),
  )
  const enabled = environment !== "production"
  assert.equal(bindsRegistry, enabled, `${environment}: registry binding must ${enabled ? "remain available for dogfood" : "wait for production promotion"}`)
  assert.equal(createsRegistry, enabled, `${environment}: registry migration must ${enabled ? "remain available for dogfood" : "wait for production promotion"}`)
  console.log(`PASS ${environment}: registry binding=${bindsRegistry}, migration=${createsRegistry}`)
}
