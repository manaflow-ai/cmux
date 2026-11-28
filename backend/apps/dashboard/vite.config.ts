import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import { readFileSync } from "node:fs"
import { createRequire } from "node:module"
import { nitro } from "nitro/vite"
import { defineConfig, type Plugin } from "vite"

const require = createRequire(import.meta.url)
const OG_RUNTIME = "virtual:og-runtime"

/**
 * `virtual:og-runtime`: the invite card's WASM renderer and fonts as base64 strings, so they
 * ship inside the server function (pinned package versions fix their content). The card route
 * imports it lazily, so other routes never load it. No HTTP self-fetch of static files.
 */
const ogRuntime = (): Plugin => ({
  name: "cmux-og-runtime",
  resolveId: (id) => (id === OG_RUNTIME ? `\0${OG_RUNTIME}` : undefined),
  load: (id) => {
    if (id !== `\0${OG_RUNTIME}`) return undefined
    const b64 = (spec: string) => JSON.stringify(readFileSync(require.resolve(spec)).toString("base64"))
    return [
      `export const resvgWasm = ${b64("@resvg/resvg-wasm/index_bg.wasm")}`,
      `export const inter700 = ${b64("@fontsource/inter/files/inter-latin-700-normal.woff")}`,
      `export const inter500 = ${b64("@fontsource/inter/files/inter-latin-500-normal.woff")}`
    ].join("\n")
  }
})

// Nitro picks the Vercel preset on Vercel builds (or NITRO_PRESET=vercel for a local prebuilt deploy).
export default defineConfig({
  plugins: [ogRuntime(), tanstackStart(), nitro(), viteReact()]
})
