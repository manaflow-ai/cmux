import React, { useEffect, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { useLocation } from "@tanstack/react-router";
import { authJsonQueryOptions } from "../convex/authJsonQueryOptions";
import { cachedGetUser } from "../../lib/cachedGetUser";
import { stackClientApp } from "../../lib/stack";
import { IPCSocketClient } from "../../lib/ipc-socket-client";
import { WebSocketContext } from "./socket-context";
import type { SocketContextType } from "./types";

// ElectronSocketProvider uses IPC to communicate with embedded server
export const ElectronSocketProvider: React.FC<React.PropsWithChildren> = ({
  children,
}) => {
  const authJsonQuery = useQuery(authJsonQueryOptions());
  const authToken = authJsonQuery.data?.accessToken;
  const location = useLocation();
  const [socket, setSocket] = React.useState<SocketContextType["socket"] | null>(null);
  const [isConnected, setIsConnected] = React.useState(false);
  const [availableEditors, setAvailableEditors] =
    React.useState<SocketContextType["availableEditors"]>(null);

  // Derive the current teamSlugOrId from the first URL segment
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
    let createdSocket: IPCSocketClient | null = null;

    (async () => {
      // Fetch full auth JSON for server
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

      console.log("[ElectronSocket] Connecting via IPC...");
      
      // Create and connect IPC socket client
      createdSocket = new IPCSocketClient(query);
      
      createdSocket.on("connect", () => {
        if (disposed) return;
        console.log("[ElectronSocket] Connected via IPC");
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
        console.log("[ElectronSocket] Available editors:", editors);
        setAvailableEditors(editors as SocketContextType["availableEditors"]);
      });

      // Connect the socket
      createdSocket.connect();

      if (!disposed) {
        // Cast to any to satisfy Socket type requirement
        setSocket(createdSocket as any);
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
    <WebSocketContext.Provider value={contextValue}>
      {children}
    </WebSocketContext.Provider>
  );
};