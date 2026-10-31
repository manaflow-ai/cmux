import { createRouter } from "@tanstack/react-router"
import { parseSearch, stringifySearch } from "./lib/search"
import { routeTree } from "./routeTree.gen"

export function getRouter() {
  return createRouter({
    routeTree,
    scrollRestoration: true,
    // A <Link> loads its route's code and loader on hover or keyboard focus, so the click shows
    // the page at once. Route loaders here are reads only (no loader writes), so a preload is safe.
    defaultPreload: "intent",
    parseSearch,
    stringifySearch,
  })
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof getRouter>
  }
}
