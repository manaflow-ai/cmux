import type { CSSProperties, ReactNode } from "react";

import { ElectronWebContentsView } from "@/components/electron-web-contents-view";
import { isElectron } from "@/lib/electron";

import { PersistentIframe } from "./persistent-iframe";

interface PersistentWebViewProps {
  persistKey: string;
  src: string;
  className?: string;
  style?: CSSProperties;
  preload?: boolean;
  allow?: string;
  sandbox?: string;
  iframeClassName?: string;
  iframeStyle?: CSSProperties;
  suspended?: boolean;
  retainOnUnmount?: boolean;
  backgroundColor?: string;
  borderRadius?: number;
  fallback?: ReactNode;
  onLoad?: () => void;
  onError?: (error: Error) => void;
  onElectronViewReady?: (info: {
    id: number;
    webContentsId: number;
    restored: boolean;
  }) => void;
  onElectronViewDestroyed?: () => void;
}

export function PersistentWebView({
  persistKey,
  src,
  className,
  style,
  preload,
  allow,
  sandbox,
  iframeClassName,
  iframeStyle,
  suspended,
  retainOnUnmount: _retainOnUnmount,
  backgroundColor,
  borderRadius,
  fallback,
  onLoad,
  onError,
  onElectronViewReady,
  onElectronViewDestroyed,
}: PersistentWebViewProps) {
  const resolvedRetain = true;

  if (isElectron) {
    return (
      <ElectronWebContentsView
        src={src}
        className={className}
        style={style}
        backgroundColor={backgroundColor}
        borderRadius={borderRadius}
        suspended={suspended}
        persistKey={persistKey}
        retainOnUnmount={resolvedRetain}
        fallback={fallback}
        onNativeViewReady={onElectronViewReady}
        onNativeViewDestroyed={onElectronViewDestroyed}
      />
    );
  }

  return (
    <PersistentIframe
      persistKey={persistKey}
      src={src}
      className={className}
      style={style}
      preload={preload}
      allow={allow}
      sandbox={sandbox}
      iframeClassName={iframeClassName}
      iframeStyle={iframeStyle}
      onLoad={onLoad}
      onError={onError}
    />
  );
}
