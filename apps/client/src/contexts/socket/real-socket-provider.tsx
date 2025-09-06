import React from "react";
import { SocketProvider } from "./socket-provider";
import { isElectron } from "@/lib/electron";
import { ElectronSocketProvider } from "./electron-socket-provider";

interface RealSocketProviderProps {
  children: React.ReactNode;
}

export const RealSocketProvider: React.FC<RealSocketProviderProps> = ({
  children,
}) => {
  return isElectron ? (
    <ElectronSocketProvider>{children}</ElectronSocketProvider>
  ) : (
    <SocketProvider>{children}</SocketProvider>
  );
};
