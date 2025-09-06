import { useContext } from "react";
import { isElectron } from "@/lib/electron";
import { ElectronSocketContext, WebSocketContext } from "./socket-context";

export const useSocket = () => {
  // Always call hooks in a consistent order
  const webCtx = useContext(WebSocketContext);
  const electronCtx = useContext(ElectronSocketContext);

  const ctx = isElectron && electronCtx ? electronCtx : webCtx;
  if (!ctx) {
    throw new Error(
      "useSocket must be used within a RealSocketProvider (web/electron)"
    );
  }
  return ctx;
};
