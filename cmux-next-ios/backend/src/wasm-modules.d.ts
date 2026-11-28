/** A `.wasm` import: wrangler and vitest-pool-workers hand it over compiled (wrangler's default `CompiledWasm` rule). */
declare module "*.wasm" {
  const module: WebAssembly.Module
  export default module
}
