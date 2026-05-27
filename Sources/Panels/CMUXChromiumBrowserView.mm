#import "CMUXChromiumBrowserView.h"

#import <dlfcn.h>

@interface CMUXChromiumRuntime ()
@property (nonatomic, readwrite, getter=isRuntimeAvailable) BOOL runtimeAvailable;
@property (nonatomic, readwrite, getter=isBrowserHostAvailable) BOOL browserHostAvailable;
@property (nonatomic, copy, readwrite, nullable) NSString *frameworkExecutablePath;
@property (nonatomic, copy, readwrite, nullable) NSString *lastErrorMessage;
@end

@implementation CMUXChromiumRuntime {
    void *_frameworkHandle;
}

+ (instancetype)sharedRuntime {
    static CMUXChromiumRuntime *runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime = [[CMUXChromiumRuntime alloc] init];
        [runtime reloadAvailability];
    });
    return runtime;
}

- (void)dealloc {
    if (_frameworkHandle != nullptr) {
        dlclose(_frameworkHandle);
        _frameworkHandle = nullptr;
    }
}

- (void)reloadAvailability {
    self.runtimeAvailable = NO;
    self.browserHostAvailable = NO;
    self.frameworkExecutablePath = nil;
    self.lastErrorMessage = nil;

    NSString *path = [self resolvedFrameworkExecutablePath];
    if (path.length == 0) {
        self.lastErrorMessage = @"Chromium Embedded Framework.framework was not found.";
        return;
    }

    if (_frameworkHandle != nullptr) {
        dlclose(_frameworkHandle);
        _frameworkHandle = nullptr;
    }

    _frameworkHandle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    if (_frameworkHandle == nullptr) {
        const char *error = dlerror();
        self.lastErrorMessage = error != nullptr
            ? [NSString stringWithUTF8String:error]
            : @"Chromium Embedded Framework.framework could not be loaded.";
        return;
    }

    self.frameworkExecutablePath = path;
    self.runtimeAvailable = YES;

    // The Swift surface can prefer Chromium before the full host is enabled, but
    // it should keep using WebKit unless an explicit host flag is present. This
    // avoids blank browser panes on builds that carry only the loader scaffold.
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *enableHost = environment[@"CMUX_CEF_ENABLE_HOST"];
    BOOL hostFlagEnabled = [enableHost isEqualToString:@"1"] ||
        (enableHost.length > 0 && [enableHost caseInsensitiveCompare:@"true"] == NSOrderedSame);
    self.browserHostAvailable = hostFlagEnabled;
    if (!self.browserHostAvailable) {
        self.lastErrorMessage = @"CEF runtime loaded, but CMUX_CEF_ENABLE_HOST is not enabled.";
    }
}

- (NSString *)resolvedFrameworkExecutablePath {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *overridePath = environment[@"CMUX_CEF_FRAMEWORK_PATH"];
    if (overridePath.length > 0) {
        if ([overridePath.lastPathComponent isEqualToString:@"Chromium Embedded Framework"]) {
            return overridePath;
        }
        return [overridePath stringByAppendingPathComponent:@"Chromium Embedded Framework"];
    }

    NSBundle *bundle = NSBundle.mainBundle;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (bundle.privateFrameworksPath.length > 0) {
        [candidates addObject:[bundle.privateFrameworksPath stringByAppendingPathComponent:@"Chromium Embedded Framework.framework/Chromium Embedded Framework"]];
    }
    if (bundle.resourcePath.length > 0) {
        [candidates addObject:[bundle.resourcePath stringByAppendingPathComponent:@"Chromium Embedded Framework.framework/Chromium Embedded Framework"]];
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *candidate in candidates) {
        if ([fileManager isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }

    return nil;
}

@end

@interface CMUXChromiumBrowserView ()
@property (nonatomic, copy, readwrite) NSString *profileIdentifier;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *extensionDirectories;
@property (nonatomic, copy, readwrite, nullable) NSString *lastCommittedURLString;
@property (nonatomic, copy, readwrite, nullable) NSString *pageTitle;
@property (nonatomic, readwrite, getter=isLoading) BOOL loading;
@property (nonatomic, readwrite) BOOL canGoBack;
@property (nonatomic, readwrite) BOOL canGoForward;
@property (nonatomic, readwrite) double estimatedProgress;
@property (nonatomic, readwrite, getter=isDeveloperToolsVisible) BOOL developerToolsVisible;
@end

@implementation CMUXChromiumBrowserView

- (instancetype)initWithProfileIdentifier:(NSString *)profileIdentifier
                     extensionDirectories:(NSArray<NSString *> *)extensionDirectories {
    self = [super initWithFrame:NSZeroRect];
    if (self == nil) {
        return nil;
    }

    _profileIdentifier = [profileIdentifier copy];
    _extensionDirectories = [extensionDirectories copy];
    _estimatedProgress = 0;
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;

    for (NSString *path in _extensionDirectories) {
        [self loadExtensionAtPath:path errorMessage:nil];
    }

    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    return YES;
}

- (void)loadURLString:(NSString *)urlString {
    self.lastCommittedURLString = urlString.length > 0 ? urlString : nil;
    self.pageTitle = self.lastCommittedURLString;
    self.loading = NO;
    self.estimatedProgress = self.lastCommittedURLString.length > 0 ? 1.0 : 0.0;
    if (self.navigationStateChanged != nil) {
        self.navigationStateChanged(self);
    }
    if (self.titleChanged != nil) {
        self.titleChanged(self);
    }
}

- (void)reloadPage {
    if (self.lastCommittedURLString.length == 0) {
        return;
    }
    [self loadURLString:self.lastCommittedURLString];
}

- (void)stopLoading {
    self.loading = NO;
    if (self.navigationStateChanged != nil) {
        self.navigationStateChanged(self);
    }
}

- (void)goBack {
}

- (void)goForward {
}

- (void)setPageZoomFactor:(double)pageZoomFactor {
    (void)pageZoomFactor;
}

- (BOOL)showDevToolsWithPresentation:(CMUXChromiumDevToolsPresentation)presentation {
    (void)presentation;
    if (!CMUXChromiumRuntime.sharedRuntime.isBrowserHostAvailable) {
        if (self.loadFailed != nil) {
            self.loadFailed(self, CMUXChromiumRuntime.sharedRuntime.lastErrorMessage ?: @"CEF browser host is unavailable.");
        }
        return NO;
    }

    self.developerToolsVisible = YES;
    return YES;
}

- (BOOL)closeDevTools {
    BOOL wasVisible = self.developerToolsVisible;
    self.developerToolsVisible = NO;
    return wasVisible;
}

- (BOOL)loadExtensionAtPath:(NSString *)path errorMessage:(NSString **)errorMessage {
    if (path.length == 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Extension path is empty.";
        }
        return NO;
    }

    if (!CMUXChromiumRuntime.sharedRuntime.isBrowserHostAvailable) {
        if (errorMessage != NULL) {
            *errorMessage = CMUXChromiumRuntime.sharedRuntime.lastErrorMessage ?: @"CEF browser host is unavailable.";
        }
        return NO;
    }

    return YES;
}

- (void)evaluateJavaScript:(NSString *)script completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    (void)script;
    if (completion == nil) {
        return;
    }

    NSError *error = [NSError errorWithDomain:@"CMUXChromiumBrowserView"
                                         code:1
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"CEF JavaScript evaluation is unavailable until the browser host is enabled."
    }];
    completion(nil, error);
}

@end
