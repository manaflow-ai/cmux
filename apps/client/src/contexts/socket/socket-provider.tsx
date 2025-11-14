import type { AvailableEditors } from "@cmux/shared";
import {
  connectToMainServer,
  type MainServerSocket,
} from "@cmux/shared/socket";
import { useQuery } from "@tanstack/react-query";
import { useLocation } from "@tanstack/react-router";
import React, { useEffect, useMemo } from "react";
import { cachedGetUser } from "../../lib/cachedGetUser";
import { stackClientApp } from "../../lib/stack";
import { authJsonQueryOptions } from "../convex/authJsonQueryOptions";
import { setGlobalSocket, socketBoot } from "./socket-boot";
import { WebSocketContext } from "./socket-context";
import { env } from "@/client-env";

export interface SocketContextType {
  socket: MainServerSocket | null;
  isConnected: boolean;
  availableEditors: AvailableEditors | null;
}

interface SocketProviderProps {
  children: React.ReactNode;
  url?: string;
}

export const SocketProvider: React.FC<SocketProviderProps> = ({
  children,
  url = env.NEXT_PUBLIC_SERVER_ORIGIN || "http://localhost:9776",
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
    console.log("[Socket] Connecting with fresh auth token");
    let disposed = false;
    let createdSocket: MainServerSocket | null = null;
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

      const newSocket = connectToMainServer({
        url,
        authToken,
        teamSlugOrId,
        authJson,
      });

      createdSocket = newSocket;
      if (disposed) {
        newSocket.disconnect();
        return;
      }
      setSocket(newSocket);
      setGlobalSocket(newSocket);
      // Signal that the provider has created the socket instance
      socketBoot.resolve();

      newSocket.on("connect", () => {
        console.log("[Socket] connected");
        setIsConnected(true);
      });

      newSocket.on("disconnect", () => {
        console.warn("[Socket] disconnected");
        setIsConnected(false);
      });

      newSocket.on("connect_error", (err) => {
        const errorMessage =
          err && typeof err === "object" && "message" in err
            ? (err as Error).message
            : String(err);
        console.error("[Socket] connect_error", errorMessage);

        // Check if this is a token expiration error
        if (
          errorMessage.includes("Token expired") ||
          errorMessage.includes("InvalidAuthHeader")
        ) {
          console.log(
            "[Socket] Token expired, will reconnect with fresh token on next auth refresh"
          );
        }
      });

      newSocket.on("available-editors", (data: AvailableEditors) => {
        setAvailableEditors(data);
      });
    })();

    return () => {
      disposed = true;
      if (createdSocket) createdSocket.disconnect();
      // Reset boot handle so future mounts can suspend appropriately
      setGlobalSocket(null);
      socketBoot.reset();
    };
  }, [url, authToken, teamSlugOrId]);

  const contextValue: SocketContextType = useMemo(
    () => ({
      socket,
      isConnected,
      availableEditors,
    }),
    [socket, isConnected, availableEditors],
  );

  return (
    <WebSocketContext.Provider value={contextValue}>
      {children}
    </WebSocketContext.Provider>
  );
};
