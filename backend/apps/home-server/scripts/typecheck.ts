/**
 * Typechecks this package. The owner classes it imports from apps/api are typechecked there with
 * Workers types only; mixed with Bun's types (needed here) the two lib.dom flavors disagree on
 * BufferSource and WebSocket statics in api files. So errors in apps/api files are left to that
 * package and only this package's own errors fail the check.
 */
const p = Bun.spawnSync(["bunx", "tsc", "-p", "."], { cwd: `${import.meta.dir}/..`, stdout: "pipe", stderr: "pipe" })
const out = p.stdout.toString() + p.stderr.toString()
const own = out.split("\n").filter((l) => /^(src|test|scripts)\//.test(l))
if (own.length) {
  console.error(own.join("\n"))
  process.exit(1)
}
console.log("home-server typecheck ok")
