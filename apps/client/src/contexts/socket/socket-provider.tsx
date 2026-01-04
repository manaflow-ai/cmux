import type { AvailableEditors } from "@cmux/shared";
import { connectToMainServer } from "@cmux/shared/socket";
import { useQuery } from "@tanstack/react-query";
import { useLocation } from "@tanstack/react-router";
import React, { useEffect, useMemo } from "react";
import { cachedGetUser } from "../../lib/cachedGetUser";
import { stackClientApp } from "../../lib/stack";
import { authJsonQueryOptions } from "../convex/authJsonQueryOptions";
import { setGlobalSocket, socketBoot } from "./socket-boot";
import { WebSocketContext } from "./socket-context";
import { env } from "@/client-env";
import type { SocketContextType, CmuxSocket } from "./types";

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
  const [socket, setSocket] = React.useState<CmuxSocket | null>(null);
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
    let createdSocket: CmuxSocket | null = null;
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

      // Define handlers as named functions so they can be removed
      const handleConnect = () => {
        console.log("[Socket] connected");
        setIsConnected(true);
      };

      const handleDisconnect = () => {
        console.warn("[Socket] disconnected");
        setIsConnected(false);
      };

      const handleConnectError = (err: unknown) => {
        const errorMessage =
          err && typeof err === "object" && "message" in err
            ? (err as Error).message
            : String(err);
        console.error("[Socket] connect_error", errorMessage);
      };

      const handleAvailableEditors = (data: AvailableEditors) => {
        setAvailableEditors(data);
      };

      newSocket.on("connect", handleConnect);
      newSocket.on("disconnect", handleDisconnect);
      newSocket.on("connect_error", handleConnectError);
      newSocket.on("available-editors", handleAvailableEditors);
    })();

    return () => {
      disposed = true;
      if (createdSocket) {
        // Remove all listeners before disconnecting to prevent memory leaks
        createdSocket.off("connect");
        createdSocket.off("disconnect");
        createdSocket.off("connect_error");
        createdSocket.off("available-editors");
        createdSocket.disconnect();
      }
      // Reset boot handle so future mounts can suspend appropriately
      setGlobalSocket(null);
      socketBoot.reset();
    };
  }, [url, authToken, teamSlugOrId]);

  useEffect(() => {
    if (!socket) return;
    let disposed = false;

    const refreshAuthentication = async () => {
      try {
        const user = await cachedGetUser(stackClientApp);
        if (!user) return;
        const authJson = await user.getAuthJson();
        const authToken = authJson?.accessToken;
        if (!authToken || !authJson || disposed) return;
        socket.emit(
          "authenticate",
          { authToken, authJson: JSON.stringify(authJson) },
          (response) => {
            if (response && !response.ok) {
              console.warn("[Socket] authenticate failed", response.error);
            }
          }
        );
      } catch (error) {
        console.error("[Socket] Failed to refresh auth", error);
      }
    };

    void refreshAuthentication();
    const intervalId = window.setInterval(refreshAuthentication, 5 * 60 * 1000);
    return () => {
      disposed = true;
      window.clearInterval(intervalId);
    };
  }, [socket]);

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
