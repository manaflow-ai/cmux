import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { unstable_readConfig } from "wrangler"

// Run manually on a Freestyle VM from backend/apps/api:
// node manual/app-registry-rollout.mjs
// Use Wrangler's resolved environment, including its binding inheritance rules.
// This is intentionally outside the CI test suite until production promotion.
const config = fileURLToPath(new URL("../wrangler.jsonc", import.meta.url))
for (const environment of ["local", "production", "development", "staging"]) {
  const resolved = unstable_readConfig({ config, ...(environment === "local" ? {} : { env: environment }) })
  const tags = resolved.migrations.map((migration) => migration.tag)
  assert.equal(new Set(tags).size, tags.length, `${environment}: migration tags must be unique`)
  const migrationsFor = (name) => resolved.migrations.filter(
    (migration) => [...(migration.new_classes ?? []), ...(migration.new_sqlite_classes ?? [])].includes(name),
  )
  assert.deepEqual(migrationsFor("TrajectoryDO").map((migration) => migration.tag), ["v20"],
    `${environment}: preserve the base trajectory migration`)
  const bindsRegistry = resolved.durable_objects.bindings.some(
    (binding) => binding.name === "APP_REGISTRY_DO" || binding.class_name === "AppRegistryDO",
  )
  const registryMigrations = migrationsFor("AppRegistryDO")
  const createsRegistry = registryMigrations.length !== 0
  const enabled = environment !== "production"
  assert.equal(bindsRegistry, enabled, `${environment}: registry binding must ${enabled ? "remain available for dogfood" : "wait for production promotion"}`)
  assert.equal(createsRegistry, enabled, `${environment}: registry migration must ${enabled ? "remain available for dogfood" : "wait for production promotion"}`)
  assert.deepEqual(registryMigrations.map((migration) => migration.tag), enabled ? ["v21"] : [],
    `${environment}: registry creation follows the base migration`)
  console.log(`PASS ${environment}: registry binding=${bindsRegistry}, migration=${createsRegistry}`)
}
