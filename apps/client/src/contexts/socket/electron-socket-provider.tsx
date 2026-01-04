import { CmuxIpcSocketClient } from "@/lib/cmux-ipc-socket-client";
import { useQuery } from "@tanstack/react-query";
import { useLocation } from "@tanstack/react-router";
import React, { useEffect, useMemo } from "react";
import { cachedGetUser } from "../../lib/cachedGetUser";
import { stackClientApp } from "../../lib/stack";
import { authJsonQueryOptions } from "../convex/authJsonQueryOptions";
import { setGlobalSocket, socketBoot } from "./socket-boot";
import { ElectronSocketContext } from "./socket-context";
import type { SocketContextType, CmuxSocket } from "./types";

export const ElectronSocketProvider: React.FC<React.PropsWithChildren> = ({
  children,
}) => {
  const authJsonQuery = useQuery(authJsonQueryOptions());
  const authToken = authJsonQuery.data?.accessToken;
  const location = useLocation();
  const [socket, setSocket] = React.useState<
    SocketContextType["socket"] | null
  >(null);
  const [isConnected, setIsConnected] = React.useState(false);
  const [availableEditors, setAvailableEditors] =
    React.useState<SocketContextType["availableEditors"]>(null);
  const teamSlugOrId = React.useMemo(() => {
    const pathname = location.pathname || "";
    const seg = pathname.split("/").filter(Boolean)[0];
    if (!seg || seg === "team-picker") return undefined;
    return seg;
  }, [location.pathname]);

  useEffect(() => {
    if (!authToken) {
      console.warn("[ElectronSocket] No auth token yet; delaying connect");
      return;
    }

    let disposed = false;
    let createdSocket: CmuxIpcSocketClient | null = null;

    (async () => {
      const user = await cachedGetUser(stackClientApp);
      const authJson = user ? await user.getAuthJson() : undefined;

      const query: Record<string, string> = { auth: authToken };
      if (teamSlugOrId) {
        query.team = teamSlugOrId;
      }
      if (authJson) {
        query.auth_json = JSON.stringify(authJson);
      }

      if (disposed) return;

      console.log("[ElectronSocket] Connecting via IPC (cmux)...");
      createdSocket = new CmuxIpcSocketClient(query);

      createdSocket.on("connect", () => {
        if (disposed) return;
        setIsConnected(true);
      });

      createdSocket.on("disconnect", () => {
        if (disposed) return;
        console.log("[ElectronSocket] Disconnected from IPC");
        setIsConnected(false);
      });

      createdSocket.on("connect_error", (error: unknown) => {
        console.error("[ElectronSocket] Connection error:", error);
      });

      createdSocket.on("available-editors", (editors: unknown) => {
        if (disposed) return;
        setAvailableEditors(editors as SocketContextType["availableEditors"]);
      });

      // Connect the socket
      createdSocket.connect();

      if (!disposed) {
        // Cast to Socket type to satisfy type requirement
        setSocket(createdSocket as unknown as CmuxSocket);
        setGlobalSocket(createdSocket as unknown as CmuxSocket);
        // Signal that the provider has created the socket instance
        socketBoot.resolve();
      }
    })();

    return () => {
      disposed = true;
      if (createdSocket) {
        console.log("[ElectronSocket] Cleaning up IPC socket");
        createdSocket.disconnect();
        setSocket(null);
        setIsConnected(false);
      }
      // Reset boot handle so future mounts can suspend appropriately
      setGlobalSocket(null);
      socketBoot.reset();
    };
  }, [authToken, teamSlugOrId]);

  const contextValue = useMemo<SocketContextType>(
    () => ({
      socket,
      isConnected,
      availableEditors,
    }),
    [socket, isConnected, availableEditors]
  );

  return (
    <ElectronSocketContext.Provider value={contextValue}>
      {children}
    </ElectronSocketContext.Provider>
  );
};
