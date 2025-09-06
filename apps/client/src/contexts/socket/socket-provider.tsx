import { useQuery } from "@tanstack/react-query";
import { useLocation } from "@tanstack/react-router";
import React, { useEffect, useMemo } from "react";
import { authJsonQueryOptions } from "../convex/authJsonQueryOptions";
import { cachedGetUser } from "../../lib/cachedGetUser";
import { stackClientApp } from "../../lib/stack";
import { WebSocketContext } from "./socket-context";
import type { SocketContextType } from "./types";
import type {
  ClientToServerEvents,
  ServerToClientEvents,
} from "@cmux/shared";
import type { Socket } from "socket.io-client";

interface SocketProviderProps {
  children: React.ReactNode;
  url?: string;
}

export const SocketProvider: React.FC<SocketProviderProps> = ({
  children,
  url = "http://localhost:9776",
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

  // Derive the current teamSlugOrId from the first URL segment, ignoring the team-picker route
  const teamSlugOrId = React.useMemo(() => {
    const pathname = location.pathname || "";
    const seg = pathname.split("/").filter(Boolean)[0];
    if (!seg || seg === "team-picker") return undefined;
    return seg;
  }, [location.pathname]);

  useEffect(() => {
    if (!authToken) {
      console.warn("[Socket] No auth token yet; delaying connect");
      return;
    }
    let disposed = false;
    let createdSocket: Socket<ServerToClientEvents, ClientToServerEvents> | null = null;
    (async () => {
      // Fetch full auth JSON for server to forward as x-stack-auth
      const user = await cachedGetUser(stackClientApp);
      const authJson = user ? await user.getAuthJson() : undefined;

      const query: Record<string, string> = { auth: authToken };
      if (teamSlugOrId) {
        query.team = teamSlugOrId;
      }
      if (authJson) {
        query.auth_json = JSON.stringify(authJson);
      }

      // Always use Socket.IO - the server runs separately
      console.log("[Socket] Using Socket.IO transport", { url });
      // Dynamic import to reduce initial bundle size
      const { io } = await import("socket.io-client");
      const newSocket = io(url, {
        transports: ["websocket"],
        query,
      });
      
      createdSocket = newSocket;
      if (disposed) {
        newSocket.disconnect();
        return;
      }
      setSocket(newSocket);

    newSocket.on("connect", () => {
      console.log("[Socket] connected", { url, team: teamSlugOrId });
      setIsConnected(true);
    });

    newSocket.on("disconnect", () => {
      console.warn("[Socket] disconnected");
      setIsConnected(false);
    });

    newSocket.on("connect_error", (err) => {
      const errorMessage = err && typeof err === 'object' && 'message' in err 
        ? (err as Error).message 
        : String(err);
      console.error("[Socket] connect_error", errorMessage);
    });

      newSocket.on("available-editors", (data) => {
        setAvailableEditors(data as SocketContextType["availableEditors"]);
      });
    })();

    return () => {
      disposed = true;
      if (createdSocket) createdSocket.disconnect();
    };
  }, [url, authToken, teamSlugOrId]);

  const contextValue: SocketContextType = useMemo(
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
