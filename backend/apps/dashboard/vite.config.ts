import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import { nitro } from "nitro/vite"
import { defineConfig } from "vite"

// Nitro picks the Vercel preset on Vercel builds (or NITRO_PRESET=vercel for a local prebuilt deploy).
export default defineConfig({
  plugins: [tanstackStart(), nitro(), viteReact()]
})
