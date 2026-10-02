import { createRouter } from "@tanstack/react-router"
import { parseSearch, stringifySearch } from "./lib/search"
import { routeTree } from "./routeTree.gen"

export function getRouter() {
  return createRouter({ routeTree, scrollRestoration: true, defaultPreload: false, parseSearch, stringifySearch })
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof getRouter>
  }
}
