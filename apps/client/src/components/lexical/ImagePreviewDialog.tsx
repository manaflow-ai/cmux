import { X, Download, ZoomIn, ZoomOut } from "lucide-react";
import { useCallback, useEffect, useState, useRef } from "react";

interface ImagePreviewDialogProps {
  isOpen: boolean;
  onClose: () => void;
  src: string;
  altText: string;
  fileName?: string;
}

export function ImagePreviewDialog({
  isOpen,
  onClose,
  src,
  altText,
  fileName,
}: ImagePreviewDialogProps) {
  const [scale, setScale] = useState(1);
  const backdropRef = useRef<HTMLDivElement>(null);

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        onClose();
      }
      if (e.key === "+" || e.key === "=") {
        setScale((s) => Math.min(s + 0.25, 3));
      }
      if (e.key === "-") {
        setScale((s) => Math.max(s - 0.25, 0.25));
      }
    },
    [onClose]
  );

  useEffect(() => {
    if (isOpen) {
      document.addEventListener("keydown", handleKeyDown);
      // Prevent scrolling on body when dialog is open
      document.body.style.overflow = "hidden";
      return () => {
        document.removeEventListener("keydown", handleKeyDown);
        document.body.style.overflow = "";
      };
    }
  }, [isOpen, handleKeyDown]);

  // Reset scale when dialog opens
  useEffect(() => {
    if (isOpen) {
      setScale(1);
    }
  }, [isOpen]);

  const handleBackdropClick = useCallback(
    (e: React.MouseEvent) => {
      if (e.target === backdropRef.current) {
        onClose();
      }
    },
    [onClose]
  );

  const handleDownload = useCallback(() => {
    const link = document.createElement("a");
    link.href = src;
    link.download = fileName || "image.png";
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  }, [src, fileName]);

  const handleZoomIn = useCallback(() => {
    setScale((s) => Math.min(s + 0.25, 3));
  }, []);

  const handleZoomOut = useCallback(() => {
    setScale((s) => Math.max(s - 0.25, 0.25));
  }, []);

  if (!isOpen) return null;

  const displayName = fileName || altText || "Image";

  return (
    <div
      ref={backdropRef}
      onClick={handleBackdropClick}
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm"
    >
      {/* Header with controls */}
      <div className="absolute top-0 left-0 right-0 flex items-center justify-between px-4 py-3 bg-gradient-to-b from-black/60 to-transparent">
        <div className="flex items-center gap-3">
          <span className="text-white text-sm font-medium truncate max-w-[300px]">
            {displayName}
          </span>
        </div>
        <div className="flex items-center gap-2">
          {/* Zoom controls */}
          <button
            type="button"
            onClick={handleZoomOut}
            className="p-2 rounded-full bg-white/10 hover:bg-white/20 text-white transition-colors"
            title="Zoom out (-)"
          >
            <ZoomOut className="w-4 h-4" />
          </button>
          <span className="text-white text-sm min-w-[60px] text-center">
            {Math.round(scale * 100)}%
          </span>
          <button
            type="button"
            onClick={handleZoomIn}
            className="p-2 rounded-full bg-white/10 hover:bg-white/20 text-white transition-colors"
            title="Zoom in (+)"
          >
            <ZoomIn className="w-4 h-4" />
          </button>

          {/* Download button */}
          <button
            type="button"
            onClick={handleDownload}
            className="p-2 rounded-full bg-white/10 hover:bg-white/20 text-white transition-colors ml-2"
            title="Download image"
          >
            <Download className="w-4 h-4" />
          </button>

          {/* Close button */}
          <button
            type="button"
            onClick={onClose}
            className="p-2 rounded-full bg-white/10 hover:bg-white/20 text-white transition-colors ml-2"
            title="Close (Esc)"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* Image container */}
      <div className="relative max-w-[90vw] max-h-[85vh] overflow-auto">
        <img
          src={src}
          alt={altText}
          className="rounded-lg shadow-2xl transition-transform duration-200"
          style={{
            transform: `scale(${scale})`,
            transformOrigin: "center center",
          }}
          draggable={false}
        />
      </div>

      {/* Hint text */}
      <div className="absolute bottom-4 left-1/2 -translate-x-1/2 text-white/60 text-xs">
        Press Esc to close, +/- to zoom
      </div>
    </div>
  );
}
