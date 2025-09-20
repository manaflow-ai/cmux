import type { CSSProperties } from "react";

import { usePersistentIframe } from "../hooks/usePersistentIframe";
import { cn } from "@/lib/utils";

interface PersistentIframeProps {
  persistKey: string;
  src: string;
  className?: string;
  style?: CSSProperties;
  preload?: boolean;
  allow?: string;
  sandbox?: string;
  iframeClassName?: string;
  iframeStyle?: CSSProperties;
  onLoad?: () => void;
  onError?: (error: Error) => void;
}

export function PersistentIframe({
  persistKey,
  src,
  className,
  style,
  preload,
  allow,
  sandbox,
  iframeClassName,
  iframeStyle,
  onLoad,
  onError,
}: PersistentIframeProps) {
  const { containerRef } = usePersistentIframe({
    key: persistKey,
    url: src,
    preload,
    allow,
    sandbox,
    className: iframeClassName,
    style: iframeStyle,
    onLoad,
    onError,
  });

  return <div ref={containerRef} className={cn(className)} style={style} />;
}
