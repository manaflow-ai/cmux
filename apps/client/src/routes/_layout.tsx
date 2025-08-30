import { convexAuthReadyPromise } from "@/contexts/convex/convex-auth-ready";
import { ConvexClientProvider } from "@/contexts/convex/convex-client-provider";
import { SocketProvider } from "@/contexts/socket/socket-provider";
import { createFileRoute, Outlet } from "@tanstack/react-router";

export const Route = createFileRoute("/_layout")({
  component: Layout,
  beforeLoad: async () => {
    await convexAuthReadyPromise;
  },
});

function Layout() {
  return (
    <ConvexClientProvider>
      <SocketProvider>
        <Outlet />
      </SocketProvider>
    </ConvexClientProvider>
  );
}
